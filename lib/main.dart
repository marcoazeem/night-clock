import 'dart:async';
import 'dart:isolate';
import 'dart:io' show InternetAddressType, NetworkInterface;
import 'dart:math';
import 'dart:ui' show ImageFilter, FontFeature;
import 'dart:ui' as ui show Image;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:lottie/lottie.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'adb.dart';
import 'gree.dart';
import 'holidays.dart';
import 'lights.dart';
import 'energy.dart';
import 'tv.dart';
import 'weather.dart';

part 'luxury.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // All four ways up: the phone stands portrait on the wireless charger and
  // gets laid on its side, off the coil, once it's full.
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const NightClockApp());
}

/// The dashboard's own ADB key for the TV box: made on first use (a 2048-bit
/// RSA key, off the UI thread), then kept in SharedPreferences so the box's
/// one-time "Allow debugging?" approval sticks.
Future<AdbKey>? _adbKey;
Future<AdbKey> _loadAdbKey() => _adbKey ??= () async {
  final prefs = await SharedPreferences.getInstance();
  final saved = prefs.getString('adbKey');
  if (saved != null) return AdbKey.fromJson(saved);
  final key = await Isolate.run(AdbKey.generate);
  await prefs.setString('adbKey', key.toJson());
  return key;
}();

class NightClockApp extends StatelessWidget {
  const NightClockApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Night Clock',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Colors.black,
        // Everything but the clock's digits.
        fontFamily: 'Inter',
      ),
      home: const ClockScreen(),
    );
  }
}

class ClockScreen extends StatefulWidget {
  const ClockScreen({super.key});

  @override
  State<ClockScreen> createState() => _ClockScreenState();
}

// The whole palette: white type, red for the date and for every digit "1".
const _red = Color(0xFFFF453A);
const _white = Color(0xFFE8E8E8);

/// Night mode, 23:00–06:00: the slate clock, and every colour shifted to
/// deep red — gentlest on eyes adjusted to the dark. `--dart-define
/// FORCE_NIGHT=true` turns it on regardless, to check it by day.
bool _isNight(DateTime t) =>
    const bool.fromEnvironment('FORCE_NIGHT') ||
    (!const bool.fromEnvironment('FORCE_MORNING') &&
        (t.hour >= 23 || t.hour < 6));

/// The hairline's tint at night.
const _nightTime = Color(0xFFFF8A75);

/// The clock's colour for the sky behind it: sunrise amber in the morning,
/// sunny yellow by day, sunset coral in the evening, steel blue in the rain;
/// after dark moonlit lavender (deep blue in the rain), and slate in red
/// night mode (23:00–06:00). The time, date and temperature all use it (the
/// fills of the old Bungee Tint palettes).
Color _clockColor(DateTime now, {required bool night, required bool raining}) {
  if (night) return const Color(0xFF56617C);
  if (_isDark(now)) {
    return raining ? const Color(0xFF6E9BD0) : const Color(0xFFB4C2FF);
  }
  if (raining) return const Color(0xFF8EC5F0);
  if (_isMorning(now)) return const Color(0xFFFFB547);
  if (_isEvening(now)) return const Color(0xFFFF8A6B);
  return const Color(0xFFFFD23F);
}

/// Holds [child] to [width], shrinking it if it would be wider. The time is
/// what should set the face width, stacked or across; without this a long
/// date or a wide platform font would, and the digits would shrink to suit.
/// The brightness presets on a dimmable light's tile.
const _presets = [1, 25, 50, 100];

/// The index of the preset nearest [level], or null.
int? _nearestPreset(int? level) => level == null
    ? null
    : _presets.indexOf(
        _presets.reduce(
          (a, b) => (a - level).abs() <= (b - level).abs() ? a : b,
        ),
      );

class _ClockScreenState extends State<ClockScreen> with WidgetsBindingObserver {
  double _dim = 0.55;

  /// The level when a press-and-hold started — non-null while adjusting,
  /// which also shows the level on screen.
  double? _dimFrom;

  // The swipe dimmer runs in two stages, because panel brightness — not pixel
  // opacity — is what actually costs battery. The top of the range walks the
  // panel down to its hardware floor; only once there does the bottom of the
  // range fade the pixels, which is the sole way to get dimmer than the floor.
  static const _panelFloor = 0.4;
  static const _minOpacity = 0.12;

  double get _panelBrightness =>
      _dim <= _panelFloor ? 0.0 : (_dim - _panelFloor) / (1 - _panelFloor);

  double get _pixelOpacity => _dim >= _panelFloor
      ? 1.0
      : _minOpacity + (_dim / _panelFloor) * (1 - _minOpacity);

  double _appliedBrightness = -1;

  DateTime _now = DateTime.now();
  Offset _drift = Offset.zero;
  bool _showHint = true;

  late final _rooms = _configuredRooms(
    configuredLights(),
    configuredAcs(),
    configuredTvs(),
    configuredBoxes(),
    configuredSwitches(),
  );

  /// The house's energy estimate, kept all the time (the home page shows
  /// it); also the home page's counts of what's on.
  late final _energy = EnergyTracker(_rooms);

  /// The room this device sits in (START_ROOM): it opens there, and goes
  /// back there after [_idleReturn] untouched.
  late final int _homeRoom = max(
    0,
    _rooms.indexWhere(
      (r) =>
          r.name.toLowerCase() ==
          const String.fromEnvironment('START_ROOM').trim().toLowerCase(),
    ),
  );

  /// The room on screen, or null for the home page (the list of rooms).
  late int? _room = _homeRoom;

  /// A locked room whose passcode pad is up (over the home page).
  int? _asking;
  Timer? _idle;
  static const _idleReturn = Duration(minutes: 2);

  /// Standby (the user asked, Nov 2026): untouched for [_standbyAfter], the
  /// whole dashboard goes true black — no video, no sky, flat outlined
  /// cards, the weather icon still — so the OLED switches most of its
  /// pixels off. Every button still works; the first touch brings the full
  /// look back.
  bool _standby = false;
  Timer? _standbyTimer;
  static const _standbyAfter = Duration(seconds: 15);

  /// Any touch restarts the count to standby (and ends it), and the walk
  /// back to this device's own room.
  void _touched() {
    _standbyTimer?.cancel();
    _standbyTimer = Timer(_standbyAfter, () {
      if (mounted && !_standby) setState(() => _standby = true);
    });
    if (_standby) setState(() => _standby = false);
    if (_rooms.length < 2) return;
    _idle?.cancel();
    _idle = Timer(_idleReturn, () {
      if (mounted && (_room != _homeRoom || _asking != null)) {
        setState(() {
          _room = _homeRoom;
          _asking = null;
        });
      }
    });
  }

  final _place = configuredPlace();
  Weather? _weather;
  Timer? _weatherTimer;

  /// Maldives holidays ("yyyyMMdd=Name"), kept in prefs for offline; the
  /// next one within 15 days sits on the hairline.
  List<String> _holidays = const [];
  DateTime? _holidaysAt;
  final _random = Random();
  Timer? _tick;
  Timer? _driftTimer;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable().catchError((_) {});
    // The face shows the draw and the bill estimate beside the weather.
    _energy.addListener(_onEnergy);
    // The brightness override needs an attached activity, which isn't there
    // yet during initState — wait for the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyBrightness(force: true);
    });
    _loadSettings();
    _startTimers();
    _touched(); // Starts the count to standby.

    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) setState(() => _showHint = false);
    });
  }

  void _onEnergy() {
    if (mounted) setState(() {});
  }

  Future<void> _refreshWeather() async {
    final place = _place;
    if (place == null) return;
    try {
      final w = await fetchWeather(place);
      if (mounted) setState(() => _weather = w);
    } catch (_) {
      // Offline: keep showing the last reading.
    }
  }

  /// Holidays ride along with the weather, fetched at most every 12 h.
  Future<void> _refreshHolidays() async {
    final at = _holidaysAt;
    if (_holidays.isNotEmpty &&
        at != null &&
        DateTime.now().difference(at) < const Duration(hours: 12)) {
      return;
    }
    try {
      final list = await fetchHolidays();
      if (list.isEmpty) return;
      _holidaysAt = DateTime.now();
      _prefs?.setStringList('holidays', list);
      _prefs?.setInt('holidaysAt', _holidaysAt!.millisecondsSinceEpoch);
      if (mounted) setState(() => _holidays = list);
    } catch (_) {
      // Offline: keep the last copy.
    }
  }

  void _startTimers() {
    _energy.start();
    _scheduleTick();
    _refreshWeather();
    _refreshHolidays();
    _weatherTimer?.cancel();
    _weatherTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      _refreshWeather();
      _refreshHolidays();
    });
    // AMOLED burn-in protection: shift the clock a few pixels every minute.
    _driftTimer?.cancel();
    _driftTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      setState(() {
        // Unit offsets in [-1, 1]; build scales them to the drift range for
        // whichever way up the phone is.
        _drift = Offset(
          _random.nextDouble() * 2 - 1,
          _random.nextDouble() * 2 - 1,
        );
      });
    });
  }

  void _stopTimers() {
    _energy.stop();
    _tick?.cancel();
    _weatherTimer?.cancel();
    _driftTimer?.cancel();
  }

  // Redraw only at the next minute boundary — one frame per minute.
  void _scheduleTick() {
    _tick?.cancel();
    final now = DateTime.now();
    final delayMs = (60 - now.second) * 1000 - now.millisecond;
    _tick = Timer(Duration(milliseconds: delayMs + 50), () {
      setState(() => _now = DateTime.now());
      _scheduleTick();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      setState(() => _now = DateTime.now());
      _startTimers();
      // Android drops the window override on backgrounding; re-assert it.
      _applyBrightness(force: true);
      _touched(); // Coming back counts as a touch: full look, new count.
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Not visible — stop burning CPU on clock updates.
      _stopTimers();
      _standbyTimer?.cancel();
      _resetBrightness();
    }
  }

  Future<void> _loadSettings() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return; // Storage unavailable; run with defaults.
    }
    if (!mounted) return;
    setState(() {
      _dim = (_prefs!.getDouble('dim') ?? 0.55).clamp(0.0, 1.0);
      _holidays = _prefs!.getStringList('holidays') ?? const [];
      final at = _prefs!.getInt('holidaysAt');
      if (at != null) _holidaysAt = DateTime.fromMillisecondsSinceEpoch(at);
    });
    _refreshHolidays();
    _applyBrightness();
    // The TV boxes' MACs, learned from the boxes themselves (see
    // AndroidTvBox): Wake-on-LAN needs them once a box is off the network.
    for (final box in _rooms.expand((r) => r.boxes)) {
      box.mac ??= _prefs!.getString('mac:${box.host}');
      box.onMacLearned = (mac) => _prefs?.setString('mac:${box.host}', mac);
    }
  }

  void _saveSettings() {
    _prefs?.setDouble('dim', _dim);
  }

  // Window-level brightness: no WRITE_SETTINGS permission, and the system
  // brightness the user set elsewhere is left untouched.
  Future<void> _applyBrightness({bool force = false}) async {
    final target = _panelBrightness;
    if (!force && (target - _appliedBrightness).abs() < 0.01) return;
    try {
      await ScreenBrightness().setApplicationScreenBrightness(target);
      _appliedBrightness = target; // Only on success, so a failed call...
    } catch (_) {
      _appliedBrightness = -1; // ...retries instead of being skipped forever.
    }
  }

  Future<void> _resetBrightness() async {
    _appliedBrightness = -1;
    try {
      await ScreenBrightness().resetApplicationScreenBrightness();
    } catch (_) {
      // Nothing to restore.
    }
  }

  @override
  void dispose() {
    _idle?.cancel();
    _standbyTimer?.cancel();
    _energy.removeListener(_onEnergy);
    WidgetsBinding.instance.removeObserver(this);
    _stopTimers();
    _resetBrightness();
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  /// The weather beside the clock: an icon for sunny, clear
  /// (after dark) or rain, and the temperature now (the user had today's
  /// low – high removed).
  /// Sized off [d], the clock's digit size, so the FittedBox scales both
  /// together.
  /// Raining now (or forced with FORCE_RAIN / FORCE_CLEAR).
  bool get _raining =>
      (_weather?.raining == true &&
          !const bool.fromEnvironment('FORCE_CLEAR')) ||
      const bool.fromEnvironment('FORCE_RAIN');

  /// The home page (every room as a card) or one room's controls.
  Widget _panel({
    required bool night,
    required double width,
    required double unit,
  }) {
    final index = _room;
    final asking = _asking;
    final Widget child;
    if (index == null && asking != null) {
      child = PinPad(
        key: ValueKey('pin$asking'),
        room: _rooms[asking],
        width: width,
        unit: unit,
        night: night,
        onCancel: () => setState(() => _asking = null),
        onUnlock: () => setState(() {
          _asking = null;
          _room = asking;
        }),
      );
    } else if (index == null) {
      // The home page keeps its cards, flat on the black.
      child = KeyedSubtree(
        key: const ValueKey('home'),
        child: _Look(
          standby: true,
          child: HomePanel(
            rooms: _rooms,
            here: _homeRoom,
            energy: _energy,
            width: width,
            unit: unit,
            night: night,
            dim: _isDark(_now),
            onOpen: _openRoom,
          ),
        ),
      );
    } else {
      final room = _rooms[index];
      child = LightsPanel(
        key: ValueKey(room.name),
        title: _rooms.length > 1 ? room.name : null,
        subtitle: room.subtitle,
        lights: room.lights,
        acs: room.acs,
        tvs: room.tvs,
        boxes: room.boxes,
        switches: room.switches,
        night: night,
        width: width,
        unit: unit,
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 250),
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        children: [...previous, ?current],
      ),
      child: child,
    );
  }

  /// Opens room [i] — through its passcode pad when it's locked and isn't
  /// this device's own room.
  void _openRoom(int i) => setState(() {
    if (_rooms[i].pin != null && i != _homeRoom) {
      _room = null;
      _asking = i;
    } else {
      _asking = null;
      _room = i;
    }
  });

  /// The rooms along the foot, text only: the one on screen in ivory with
  /// a gold dot under it (the luxury look; it replaced the header's house
  /// button).
  Widget _roomTabs(double s, bool night) {
    final gold = _goldFor(night);
    Widget tab(String label, bool active, VoidCallback onTap) =>
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: 6 * s, vertical: 10 * s),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: _caps(
                    9.5 * s,
                    color: active ? _ivory : _muted,
                    spacing: 0.26,
                    weight: active ? FontWeight.w500 : FontWeight.w400,
                  ),
                ),
                SizedBox(height: 6 * s),
                Container(
                  width: 3 * s,
                  height: 3 * s,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active ? gold : Colors.transparent,
                  ),
                ),
              ],
            ),
          ),
        );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        tab(
          'HOME',
          _room == null && _asking == null,
          () => setState(() {
            _room = null;
            _asking = null;
          }),
        ),
        for (final (i, r) in _rooms.indexed)
          tab(
            r.name.split(' ').first.toUpperCase(),
            _room == i || _asking == i,
            () => _openRoom(i),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Always 24-hour: the user dropped the 12h/AM-PM and seconds options.
    final hh = _now.hour.toString().padLeft(2, '0');
    final mm = _now.minute.toString().padLeft(2, '0');
    final night = _isNight(_now);
    final timeColor = night ? _nightTime : _ivory;
    // Ivory by day; night mode keeps its slate clock.
    final clockColor = night
        ? _clockColor(_now, night: true, raining: _raining)
        : _ivory;
    final onHome = _room == null && _rooms.length > 1;
    // Only the picture follows the weather: rain whenever it rains, the
    // night clip after dark, the sunny one by day; the home page's forest.
    final clip = onHome
        ? 'homescreen'
        : _raining
        ? 'rainy'
        : night || _isDark(_now)
        ? 'night'
        : 'sunny';

    return Scaffold(
      backgroundColor: Colors.black,
      body: Listener(
        onPointerDown: (_) => _touched(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          // Brightness: press and hold, then slide up / down. A plain swipe
          // used to do it, which fired on picking the phone up and fought
          // the panel's scrolling.
          onLongPressStart: (_) {
            HapticFeedback.selectionClick();
            setState(() => _dimFrom = _dim);
          },
          onLongPressMoveUpdate: (d) {
            final from = _dimFrom;
            if (from == null) return;
            setState(() {
              _dim = (from - d.offsetFromOrigin.dy / 400).clamp(0.0, 1.0);
            });
            _applyBrightness(); // Live, so the slide reads as one gesture.
          },
          onLongPressEnd: (_) {
            setState(() => _dimFrom = null);
            _applyBrightness(force: true);
            _saveSettings();
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              final w = constraints.maxWidth;
              final h = constraints.maxHeight;
              // Standing on the charger, or on its side once it's full.
              final landscape = w > h;
              // Sizes are the mock-up's, drawn on this phone standing (411
              // wide), scaled by the short side.
              final barSpan = min(w, h);
              final s = barSpan / 411;
              // Burn-in drift: a few pixels a minute.
              final driftX = (landscape ? 10.0 : 6.0) * s;
              final driftY = (landscape ? 6.0 : 10.0) * s;
              final pad = 14 * s;

              final weather = _weather;
              final holiday = holidayLine(_holidays, _now);
              // The fading rule under the time; three alphas along it.
              Widget hairline(double a, double b, double c) => Container(
                height: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      timeColor.withValues(alpha: a),
                      timeColor.withValues(alpha: b),
                      timeColor.withValues(alpha: c),
                    ],
                  ),
                ),
              );
              final watts = onHome ? null : _energy.draw?.total;
              final bill = _energy.enabled ? _energy.projectedMvr : null;

              final face = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${_weekdaysFull[_now.weekday - 1]}  ·  '
                            '${_now.day} ${_monthsFull[_now.month - 1]}'
                        .toUpperCase(),
                    style: _caps(10.5 * s, spacing: 0.33),
                  ),
                  SizedBox(height: 2 * s),
                  Text(
                    '$hh:$mm',
                    style: TextStyle(
                      fontFamily: _jost,
                      fontWeight: FontWeight.w200,
                      fontSize: (landscape ? 84 : 100) * s,
                      height: 1.04,
                      letterSpacing: 2 * s,
                      color: clockColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  SizedBox(height: 2 * s),
                  // The next holiday sits on the hairline, in red (the user
                  // asked); with none near, the hairline alone.
                  Row(
                    children: [
                      Expanded(child: hairline(0, 0.1, 0.24)),
                      if (holiday != null) ...[
                        SizedBox(width: 12 * s),
                        Flexible(
                          flex: 4,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              holiday,
                              style: _caps(
                                10 * s,
                                color: _holidayRed,
                                spacing: 0.3,
                              ),
                            ),
                          ),
                        ),
                        SizedBox(width: 12 * s),
                      ],
                      Expanded(child: hairline(0.24, 0.1, 0)),
                    ],
                  ),
                  if (weather != null) ...[
                    SizedBox(height: 10 * s),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _meteocon(weather, 34 * s, night),
                        SizedBox(width: 8 * s),
                        Text(
                          '${weather.temp}°',
                          style: TextStyle(
                            fontFamily: _jost,
                            fontWeight: FontWeight.w300,
                            fontSize: 24 * s,
                            height: 1,
                            color: clockColor,
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              );

              final title = _asking != null
                  ? _rooms[_asking!].name
                  : _room != null
                  ? _rooms[_room!].name
                  : _rooms.length > 1
                  ? 'Home'
                  : null;
              final header = title == null
                  ? const SizedBox()
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        title.toUpperCase(),
                        style: _caps(11 * s, spacing: 0.32),
                      ),
                    );
              // The bill, inside the foot of the picture (the user asked).
              final energyLine = watts == null
                  ? null
                  : Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4 * s),
                      child: Row(
                        children: [
                          Text('ENERGY', style: _caps(9.5 * s, spacing: 0.32)),
                          const Spacer(),
                          Text(
                            [
                              _kw(watts),
                              if (bill != null) '≈ MVR ${_mvr(bill)}',
                            ].join('  ·  ').toUpperCase(),
                            style: _caps(
                              10 * s,
                              color: _ivory.withValues(alpha: 0.85),
                              spacing: 0.2,
                            ),
                          ),
                          if (bill != null)
                            Text(
                              '  THIS BILL',
                              style: _caps(9.5 * s, spacing: 0.25),
                            ),
                        ],
                      ),
                    );
              // The picture runs behind the date and time, faint there so
              // they read, full under the weather, dim behind the bill.
              Widget picture(double timeEnd, double solid, double shade) =>
                  _LuxPicture(
                    clip: clip,
                    standby: _standby,
                    night: night,
                    still: night || _isDark(_now),
                    stops: [0, timeEnd, solid, shade, 0.93, 1],
                    alphas: [0, 0.22, 1, 1, energyLine == null ? 0.1 : 0.3, 0],
                  );
              final tabs = _rooms.length > 1 ? _roomTabs(s, night) : null;
              final unit = barSpan * 0.034;

              final Widget body;
              if (landscape) {
                final left = w * 0.42;
                final panelWidth = w - 2 * (driftX + pad) - left - 20 * s;
                body = Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: left,
                      child: Column(
                        children: [
                          header,
                          SizedBox(height: 8 * s),
                          Expanded(
                            child: Stack(
                              children: [
                                Positioned.fill(child: picture(0.3, 0.55, 0.8)),
                                Column(
                                  children: [
                                    face,
                                    const Spacer(),
                                    ?energyLine,
                                    SizedBox(height: 8 * s),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    SizedBox(width: 20 * s),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              child: _panel(
                                night: night,
                                width: panelWidth,
                                unit: unit,
                              ),
                            ),
                          ),
                          ?tabs,
                        ],
                      ),
                    ),
                  ],
                );
              } else {
                body = Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8 * s),
                      child: header,
                    ),
                    SizedBox(height: 14 * s),
                    Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: -(driftX + pad),
                          right: -(driftX + pad),
                          top: 0,
                          bottom: 0,
                          child: picture(0.3, 0.6, 0.8),
                        ),
                        Column(
                          children: [
                            face,
                            SizedBox(height: 92 * s),
                            ?energyLine,
                            SizedBox(height: 12 * s),
                          ],
                        ),
                      ],
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: _panel(
                          night: night,
                          width: w - 2 * (driftX + pad),
                          unit: unit,
                        ),
                      ),
                    ),
                    ?tabs,
                  ],
                );
              }

              return _Look(
                standby: _standby,
                child: Opacity(
                  opacity: _pixelOpacity,
                  child: Stack(
                    children: [
                      // A plain jump, once a minute.
                      Transform.translate(
                        offset: Offset(_drift.dx * driftX, _drift.dy * driftY),
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(
                            driftX + pad,
                            driftY + pad,
                            driftX + pad,
                            driftY + 2 * s,
                          ),
                          child: body,
                        ),
                      ),
                      if (_dimFrom != null)
                        Positioned(
                          left: 0,
                          right: 0,
                          top: barSpan * 0.08,
                          child: Center(
                            child: _LuxCard(
                              radius: 20,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.brightness_6_outlined,
                                    size: 16,
                                    color: _muted,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    '${(_dim * 100).round()}%',
                                    style: const TextStyle(
                                      color: _ivory,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w400,
                                      letterSpacing: 1,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (_showHint)
                        Positioned(
                          left: 0,
                          right: 0,
                          top: 4 * s,
                          child: Center(
                            child: Text(
                              'PRESS & HOLD, THEN SLIDE TO DIM',
                              style: _caps(9 * s, spacing: 0.3),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

// ── Dashboard palette ──────────────────────────────────────────────────────
// Every device keeps its own colour, faint while off and glowing while on,
// so what's on reads from across the room. The clock keeps white and red.
const _warm = Color(0xFFFFB547);
const _tvViolet = Color(0xFFB69CFF);

const _acCool = Color(0xFF4FD8EB);

const _acModeNames = ['Auto', 'Cool', 'Dry', 'Fan', 'Heat'];

/// Night mode: every hue is pulled most of the way to this deep red.
const _nightRed = Color(0xFFFF4A3D);

/// [c], or its night version: mostly red, a trace of its own hue left so
/// the devices still differ.
Color _hue(Color c, bool night) => night ? Color.lerp(c, _nightRed, 0.8)! : c;

/// Neutral surfaces for buttons that aren't a device's own colour.
final _surface = _white.withValues(alpha: 0.06);
final _surfaceEdge = _white.withValues(alpha: 0.10);

/// Morning, the sun rising beside the clock: 06:00–11:00.
bool _isMorning(DateTime t) =>
    const bool.fromEnvironment('FORCE_MORNING') || (t.hour >= 6 && t.hour < 11);

/// Sunset colours: 17:00–19:00. Near the equator it's dark by 19:00 all
/// year, and from then the sky is the starry one — night mode's red
/// (23:00) is a separate, later switch.
bool _isEvening(DateTime t) => t.hour >= 17 && t.hour < 19;

/// After dark: the starry sky, 19:00–06:00 (or whenever night mode is on).
bool _isDark(DateTime t) =>
    !const bool.fromEnvironment('FORCE_MORNING') &&
    (t.hour >= 19 || t.hour < 6);

/// A looping, silent video — the user's sunny / rainy / night clips,
/// shrunk to 1280×720 at 15 fps (hardware-decoded), now played only in the
/// luxury face's picture strip. Shows
/// [fallback] until the video is ready, or for good if it can't load (the
/// clips are gitignored, so a fresh clone has none). Pauses whenever the
/// app is off screen, and mixes with other audio so it never pauses music.
class _VideoSky extends StatefulWidget {
  const _VideoSky({required this.asset, required this.fallback});
  final String asset;
  final Widget fallback;

  @override
  State<_VideoSky> createState() => _VideoSkyState();
}

class _VideoSkyState extends State<_VideoSky> with WidgetsBindingObserver {
  VideoPlayerController? _video;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _open();
  }

  void _open() {
    final video = VideoPlayerController.asset(
      widget.asset,
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _video = video;
    video
        .initialize()
        .then((_) async {
          if (!mounted || _video != video) return;
          await video.setVolume(0);
          await video.setLooping(true);
          await video.play();
          if (mounted) setState(() => _ready = true);
        })
        .catchError((_) {
          // No clip (or it won't decode): the fallback stays.
        });
  }

  @override
  void didUpdateWidget(_VideoSky old) {
    super.didUpdateWidget(old);
    if (old.asset != widget.asset) {
      _video?.dispose();
      _ready = false;
      _open();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_ready) _video?.play();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _video?.pause();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _video?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final video = _video;
    if (!_ready || video == null) return widget.fallback;
    return FittedBox(
      fit: BoxFit.cover,
      clipBehavior: Clip.hardEdge,
      child: SizedBox(
        width: video.value.size.width,
        height: video.value.size.height,
        child: VideoPlayer(video),
      ),
    );
  }
}

/// The look the dashboard is in — standby (true black, flat cards) or the
/// full glass look — read by the cards wherever they sit in the tree.
class _Look extends InheritedWidget {
  const _Look({required this.standby, required super.child});
  final bool standby;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_Look>()?.standby ?? false;

  @override
  bool updateShouldNotify(_Look old) => old.standby != standby;
}

/// A frosted-glass card in its device's [hue]: the backdrop blurred through
/// it, a wash of the hue, a thin border that's brightest top-left and fades
/// out, and a glow around it while [on]. [alert] turns the border red. In
/// standby ([_Look]) it's just the border on black.
class _GlowCard extends StatelessWidget {
  const _GlowCard({
    required this.hue,
    required this.on,
    required this.unit,
    required this.child,
    this.width,
    this.height,
    this.alert = false,
  });

  /// Inner padding, in units.
  final double padding = 1.1;

  final Color hue;
  final bool on;
  final double unit;
  final Widget child;
  final double? width;
  final double? height;
  final bool alert;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(unit * 1.8);
    final standby = _Look.of(context);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: on && !standby
            ? [
                BoxShadow(
                  color: hue.withValues(alpha: 0.28),
                  blurRadius: unit * 2.6,
                  spreadRadius: -unit * 0.4,
                ),
              ]
            : null,
      ),
      // Tinted glass without a live blur: re-blurring the animated sky on
      // every frame cost ~440 mA with the rest of the app — more than slow
      // wireless charging delivers. The sky is soft gradients anyway.
      child: ClipRRect(
        borderRadius: r,
        child: CustomPaint(
          foregroundPainter: _EdgePainter(
            color: alert ? _red : hue,
            strength: on ? 0.85 : 0.4,
            radius: unit * 1.8,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 400),
            padding: EdgeInsets.all(unit * padding),
            decoration: BoxDecoration(
              gradient: standby
                  ? null
                  : LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color.alphaBlend(
                          hue.withValues(alpha: on ? 0.22 : 0.07),
                          _white.withValues(alpha: 0.09),
                        ),
                        Color.alphaBlend(
                          hue.withValues(alpha: on ? 0.06 : 0.0),
                          _white.withValues(alpha: 0.035),
                        ),
                      ],
                    ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The White Light's colour-temperature sheet: the light's name and its
/// kelvin, a thick warm → cool slider (candle to daylight) whose knob
/// carries the colour, and the 1 / 25 / 50 / 100% presets. Drags send
/// at most every 0.4 s and once more on release.
class _KelvinSheet extends StatefulWidget {
  const _KelvinSheet({
    required this.light,
    required this.unit,
    required this.night,
    required this.state,
    required this.onState,
  });

  final Light light;
  final double unit;
  final bool night;
  final LightState state;
  final ValueChanged<LightState> onState;

  @override
  State<_KelvinSheet> createState() => _KelvinSheetState();
}

class _KelvinSheetState extends State<_KelvinSheet> {
  late int _kelvin = widget.state.kelvin ?? 4000;
  late int? _level = widget.state.brightness;
  late bool _on = widget.state.on;
  DateTime _sent = DateTime(0);
  bool _failed = false;

  Light get light => widget.light;

  LightState get _now => LightState(_on, _level, _kelvin);

  Future<void> _send({bool force = false}) async {
    final now = DateTime.now();
    if (!force && now.difference(_sent) < const Duration(milliseconds: 400)) {
      return;
    }
    _sent = now;
    final k = _kelvin;
    try {
      await light.setKelvin(k);
      _failed = false;
      widget.onState(_now);
    } catch (_) {
      _failed = true;
    }
    if (mounted) setState(() {});
  }

  Future<void> _preset(int pct) async {
    setState(() {
      _level = pct;
      _on = true;
    });
    try {
      await light.setBrightness(pct);
      _failed = false;
      widget.onState(_now);
    } catch (_) {
      _failed = true;
    }
    if (mounted) setState(() {});
  }

  void _at(double x, double w) {
    final t = (x / w).clamp(0.0, 1.0);
    final k = (light.minKelvin + t * (light.maxKelvin - light.minKelvin))
        .round();
    // Snap to 50 K so the readout doesn't flicker through every value.
    setState(() => _kelvin = (k / 50).round() * 50);
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.unit;
    final night = widget.night;
    final hue = _hue(_kelvinColor(_kelvin), night);
    final t = (_kelvin - light.minKelvin) / (light.maxKelvin - light.minKelvin);
    final media = MediaQuery.of(context);
    final width = min(media.size.width - 32, u * 34);
    final trackH = u * 3.2;

    Text label(String s, {double a = 0.55, double size = 0.75}) => Text(
      s,
      style: TextStyle(
        color: _white.withValues(alpha: a),
        fontSize: u * size,
        fontWeight: FontWeight.w500,
      ),
    );

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: u * 1.2),
        child: Center(
          heightFactor: 1,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(u * 1.8),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
              child: Container(
                width: width,
                padding: EdgeInsets.all(u * 1.4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(u * 1.8),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color.alphaBlend(
                        hue.withValues(alpha: _on ? 0.22 : 0.08),
                        const Color(0xE61A1C22),
                      ),
                      const Color(0xF0121318),
                    ],
                  ),
                  border: Border.all(color: _white.withValues(alpha: 0.12)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          width: u * 2.8,
                          height: u * 2.8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: hue.withValues(alpha: _on ? 0.9 : 0.15),
                            boxShadow: _on
                                ? [
                                    BoxShadow(
                                      color: hue.withValues(alpha: 0.6),
                                      blurRadius: u * 1.2,
                                    ),
                                  ]
                                : null,
                          ),
                          child: Icon(
                            Icons.lightbulb_rounded,
                            size: u * 1.5,
                            color: _on
                                ? Colors.black.withValues(alpha: 0.75)
                                : hue,
                          ),
                        ),
                        SizedBox(width: u * 0.9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                light.name,
                                style: TextStyle(
                                  color: _white,
                                  fontSize: u * 1.15,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              label(
                                _failed
                                    ? 'Not answering'
                                    : _on
                                    ? 'Colour temperature'
                                    : 'Off — the colour applies when it turns on',
                                a: _failed ? 1 : 0.55,
                              ),
                            ],
                          ),
                        ),
                        Text(
                          '$_kelvin K',
                          style: TextStyle(
                            color: hue,
                            fontSize: u * 1.5,
                            fontWeight: FontWeight.w400,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: u * 1.6),
                    LayoutBuilder(
                      builder: (context, c) {
                        final w = c.maxWidth;
                        final knob = trackH + u * 0.6;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapDown: (d) {
                            _at(d.localPosition.dx, w);
                            _send(force: true);
                          },
                          onHorizontalDragStart: (d) =>
                              _at(d.localPosition.dx, w),
                          onHorizontalDragUpdate: (d) {
                            _at(d.localPosition.dx, w);
                            _send();
                          },
                          onHorizontalDragEnd: (_) => _send(force: true),
                          child: SizedBox(
                            height: knob,
                            child: Stack(
                              clipBehavior: Clip.none,
                              alignment: Alignment.centerLeft,
                              children: [
                                Container(
                                  height: trackH,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                      trackH / 2,
                                    ),
                                    gradient: LinearGradient(
                                      colors: [
                                        for (final k in [
                                          1700,
                                          2400,
                                          3200,
                                          4200,
                                          5200,
                                          6500,
                                        ])
                                          _hue(_kelvinColor(k), night),
                                      ],
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(
                                          alpha: 0.35,
                                        ),
                                        blurRadius: u * 0.4,
                                        offset: Offset(0, u * 0.1),
                                      ),
                                    ],
                                  ),
                                  // A soft top highlight, like a glass rod.
                                  foregroundDecoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                      trackH / 2,
                                    ),
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [
                                        Colors.white.withValues(alpha: 0.28),
                                        Colors.white.withValues(alpha: 0),
                                        Colors.black.withValues(alpha: 0.12),
                                      ],
                                    ),
                                  ),
                                ),
                                Positioned(
                                  left: (t * (w - knob)).clamp(0, w - knob),
                                  child: Container(
                                    width: knob,
                                    height: knob,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: _hue(_kelvinColor(_kelvin), night),
                                      border: Border.all(
                                        color: Colors.white,
                                        width: u * 0.28,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withValues(
                                            alpha: 0.45,
                                          ),
                                          blurRadius: u * 0.7,
                                          offset: Offset(0, u * 0.15),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                    SizedBox(height: u * 0.6),
                    Row(
                      children: [
                        Icon(
                          Icons.local_fire_department_rounded,
                          size: u * 0.9,
                          color: _hue(_kelvinColor(1700), night),
                        ),
                        SizedBox(width: u * 0.3),
                        label('Candle'),
                        const Spacer(),
                        label('Daylight'),
                        SizedBox(width: u * 0.3),
                        Icon(
                          Icons.wb_sunny_rounded,
                          size: u * 0.9,
                          color: _hue(_kelvinColor(6500), night),
                        ),
                      ],
                    ),
                    if (light.dimmable) ...[
                      SizedBox(height: u * 1.4),
                      Row(
                        children: [
                          for (final (i, pct) in _presets.indexed) ...[
                            if (i > 0) SizedBox(width: u * 0.6),
                            Expanded(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: () => _preset(pct),
                                child: AnimatedContainer(
                                  duration: const Duration(milliseconds: 250),
                                  height: u * 2.8,
                                  alignment: Alignment.center,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                      u * 1.4,
                                    ),
                                    color: _on && _nearestPreset(_level) == i
                                        ? hue
                                        : _surface,
                                    border: Border.all(color: _surfaceEdge),
                                  ),
                                  child: Text(
                                    '$pct%',
                                    style: TextStyle(
                                      color: _on && _nearestPreset(_level) == i
                                          ? Colors.black
                                          : _white.withValues(alpha: 0.75),
                                      fontSize: u * 0.85,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A colour temperature as a colour (Tanner Helland's fit, softened so
/// 6500 K reads as daylight rather than blue).
Color _kelvinColor(int kelvin) {
  final t = kelvin / 100;
  double r, g, b;
  if (t <= 66) {
    r = 255;
    g = 99.47 * log(t) - 161.12;
    b = t <= 19 ? 0 : 138.52 * log(t - 10) - 305.04;
  } else {
    r = 329.7 * pow(t - 60, -0.1332);
    g = 288.12 * pow(t - 60, -0.0755);
    b = 255;
  }
  int c(double v) => v.clamp(0, 255).round();
  // The raw curve is pale near the middle; pull it towards the app's amber
  // at the warm end so the strip runs amber → white → sky.
  final raw = Color.fromARGB(255, c(r), c(g), c(b));
  // …and towards icy sky at the cool end, so daylight isn't plain white.
  final warmth = ((3500 - kelvin) / 1800).clamp(0.0, 1.0);
  final coolness = ((kelvin - 4500) / 2000).clamp(0.0, 1.0);
  return Color.lerp(
    Color.lerp(raw, _warm, warmth * 0.6)!,
    const Color(0xFFA8D4FF),
    coolness * 0.7,
  )!;
}

/// A card's 1.2 px border, [color] at the top-left corner fading to a
/// whisper of white at the bottom-right.
class _EdgePainter extends CustomPainter {
  _EdgePainter({
    required this.color,
    required this.strength,
    required this.radius,
  });
  final Color color;
  final double strength;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    const w = 1.2;
    final rect = (Offset.zero & size).deflate(w / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius - w / 2)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            color.withValues(alpha: strength),
            color.withValues(alpha: strength * 0.15),
            _white.withValues(alpha: 0.08),
          ],
          stops: const [0, 0.55, 1],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_EdgePainter old) =>
      old.color != color || old.strength != strength || old.radius != radius;
}

/// The dashboard under (or beside) the clock: a tile per light, a tile per
/// AC, and a card per TV. Lights and TVs poll here every 15 s while the app
/// is on screen; each AC tile polls itself.
/// One room of the house and the devices in it.
class Room {
  Room(
    this.name,
    this.subtitle,
    this.lights,
    this.acs,
    this.tvs,
    this.boxes, {
    this.pin,
    this.switches = const [],
  });
  final String name;

  /// A passcode to open it from the home page (ROOM_PINS), or null.
  final String? pin;

  /// What it's also called ("Master Bedroom"), shown under its name.
  final String? subtitle;
  final List<Light> lights;
  final List<GreeAc> acs;
  final List<HisenseTv> tvs;
  final List<AndroidTvBox> boxes;

  /// Sonoff wall switches (fans and lights) — placeholders for now.
  final List<SonoffSwitch> switches;

  bool get isEmpty =>
      lights.isEmpty &&
      acs.isEmpty &&
      tvs.isEmpty &&
      boxes.isEmpty &&
      switches.isEmpty;

  /// "2 lights · 2 ACs · 1 TV", or "No devices yet".
  String get summary {
    String n(int count, String one) => '$count $one${count == 1 ? '' : 's'}';
    final fans = switches.where((s) => s.isFan).length;
    final lamps = lights.length + switches.length - fans;
    final parts = [
      if (lamps > 0) n(lamps, 'light'),
      if (fans > 0) n(fans, 'fan'),
      if (acs.isNotEmpty) n(acs.length, 'AC'),
      if (tvs.length + boxes.length > 0) n(tvs.length + boxes.length, 'TV'),
    ];
    return parts.isEmpty ? 'No devices yet' : parts.join(' · ');
  }
}

/// The rooms from `ROOMS` in lights.json:
/// `"Bedroom (Master)=Bed,Desk,Bedroom AC; Kitchen="` — each room's name,
/// an optional subtitle in brackets, and its devices by name. Without
/// `ROOMS` everything is one room and there's no home page.
List<Room> _configuredRooms(
  List<Light> lights,
  List<GreeAc> acs,
  List<HisenseTv> tvs,
  List<AndroidTvBox> boxes, [
  List<SonoffSwitch> switches = const [],
]) {
  const spec = String.fromEnvironment('ROOMS');
  if (spec.trim().isEmpty) {
    return [Room('Room', null, lights, acs, tvs, boxes, switches: switches)];
  }
  // ROOM_PINS: "Room=1234; Other Room=5678" — rooms that ask for a code.
  final pins = <String, String>{
    for (final p in const String.fromEnvironment('ROOM_PINS').split(';'))
      if (p.contains('='))
        p.substring(0, p.indexOf('=')).trim().toLowerCase(): p
            .substring(p.indexOf('=') + 1)
            .trim(),
  };
  final rooms = <Room>[];
  for (final part in spec.split(';')) {
    final eq = part.indexOf('=');
    if (eq < 0) continue;
    final head = RegExp(
      r'^(.*?)\s*(?:\((.*)\))?$',
    ).firstMatch(part.substring(0, eq).trim())!;
    final names = {
      for (final n in part.substring(eq + 1).split(','))
        if (n.trim().isNotEmpty) n.trim().toLowerCase(),
    };
    bool has(String name) => names.contains(name.toLowerCase());
    rooms.add(
      Room(
        head.group(1)!,
        head.group(2),
        [
          for (final l in lights)
            if (has(l.name)) l,
        ],
        [
          for (final a in acs)
            if (has(a.name)) a,
        ],
        [
          for (final t in tvs)
            if (has(t.name)) t,
        ],
        [
          for (final b in boxes)
            if (has(b.name)) b,
        ],
        pin: pins[head.group(1)!.toLowerCase()],
        switches: [
          for (final s in switches)
            if (has(s.name)) s,
        ],
      ),
    );
  }
  return rooms.isEmpty
      ? [Room('Room', null, lights, acs, tvs, boxes, switches: switches)]
      : rooms;
}

/// The home page: every room as a card; tap one to open it.
class HomePanel extends StatelessWidget {
  const HomePanel({
    super.key,
    required this.rooms,
    required this.here,
    required this.width,
    required this.unit,
    required this.onOpen,
    required this.energy,
    this.night = false,
    this.dim = false,
    this.blueprint,
  });

  final List<Room> rooms;
  final EnergyTracker energy;

  /// The room this device sits in, marked "Here".
  final int here;
  final double width;
  final double unit;
  final bool night;

  /// After dark: the house render is dimmed.
  final bool dim;

  /// The house render — for tests; the app's is assets/images/blueprint.png.
  final ImageProvider? blueprint;
  final ValueChanged<int> onOpen;

  static IconData iconFor(String name) {
    final n = name.toLowerCase();
    if (n.contains('kitchen')) return Icons.kitchen_rounded;
    if (n.contains('sitting') || n.contains('living') || n.contains('lounge')) {
      return Icons.weekend_rounded;
    }
    return Icons.bed_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final u = unit;
    final gap = u * 0.8;
    final amber = _hue(_warm, night);
    return SizedBox(
      width: width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelHeader(
            unit: u,
            night: night,
            title: 'HOME',
            subtitle: '${rooms.length} rooms',
            icon: Icons.home_rounded,
          ),
          SizedBox(height: gap),
          ListenableBuilder(
            listenable: energy,
            builder: (context, _) => _HouseView(
              rooms: rooms,
              here: here,
              states: energy.roomStates,
              width: width,
              unit: u,
              night: night,
              dim: dim,
              onOpen: onOpen,
              image:
                  blueprint ??
                  const ResizeImage(
                    AssetImage('assets/images/blueprint.png'),
                    width: 900,
                  ),
              cards: (indices) => _cards(indices, amber),
            ),
          ),
          SizedBox(height: gap),
          ListenableBuilder(
            listenable: energy,
            builder: (context, _) => Column(
              children: [
                _HomeStats(energy: energy, width: width, unit: u, night: night),
                if (energy.enabled) ...[
                  SizedBox(height: gap),
                  _EnergyCard(
                    energy: energy,
                    width: width,
                    unit: u,
                    night: night,
                  ),
                ],
              ],
            ),
          ),
          SizedBox(height: gap),
          _HomeStatus(unit: u, night: night),
        ],
      ),
    );
  }

  /// The rooms in [indices] as cards, two to a row: the home page before
  /// the house render, and still what a room gets when it has no place on
  /// the render — or every room, when the render is missing.
  Widget _cards(List<int> indices, Color amber) {
    final u = unit;
    final gap = u * 0.8;
    final tile = (width - gap) / 2;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (final i in indices)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onOpen(i),
            child: _GlowCard(
              hue: amber,
              on: false,
              unit: u,
              width: tile,
              height: u * 9,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: u * 2.6,
                        height: u * 2.6,
                        decoration: BoxDecoration(
                          color: _white.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(u * 0.8),
                        ),
                        child: Icon(
                          iconFor(rooms[i].name),
                          size: u * 1.5,
                          color: rooms[i].isEmpty
                              ? _white.withValues(alpha: 0.4)
                              : amber,
                        ),
                      ),
                      const Spacer(),
                      if (rooms[i].pin != null && i != here)
                        Icon(
                          Icons.lock_rounded,
                          size: u * 1.1,
                          color: _white.withValues(alpha: 0.45),
                        ),
                      if (i == here)
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: u * 0.6,
                            vertical: u * 0.2,
                          ),
                          decoration: BoxDecoration(
                            color: amber.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(u),
                          ),
                          child: Text(
                            'Here',
                            style: TextStyle(
                              color: amber,
                              fontSize: u * 0.65,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const Spacer(),
                  Text(
                    rooms[i].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _white,
                      fontSize: u * 1.0,
                      fontWeight: FontWeight.w500,
                      height: 1.2,
                    ),
                  ),
                  Text(
                    rooms[i].subtitle ?? rooms[i].summary,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _white.withValues(alpha: 0.5),
                      fontSize: u * 0.72,
                      fontWeight: FontWeight.w500,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

// ── House (home page) ────────────────────────────────────────────────────

/// What's on in one room right now, from the house-wide poll.
class RoomState {
  const RoomState({
    this.lightsOn = 0,
    this.level,
    this.cooling = 0,
    this.screensOn = 0,
  });
  final int lightsOn;

  /// The brightest lit light's level, 1–100.
  final int? level;
  final int cooling;
  final int screensOn;

  bool get quiet => lightsOn == 0 && cooling == 0 && screensOn == 0;

  /// "1 light on · cooling · TV on", or null when nothing is.
  String? get line {
    final parts = [
      if (lightsOn > 0) '$lightsOn light${lightsOn == 1 ? '' : 's'} on',
      if (cooling > 0) 'cooling',
      if (screensOn > 0) '${screensOn == 1 ? 'TV' : '$screensOn TVs'} on',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }
}

/// Where a room sits on the render (assets/images/blueprint.png, the
/// user's apartment), in fractions of the image: the floor to tap, where
/// its glow pools, where its label's stem lands, and its TV screens.
class _Plot {
  const _Plot({
    required this.keys,
    required this.floor,
    required this.centre,
    required this.foot,
    this.generic = const [],
    this.right = false,
    this.screens = const [],
  });

  /// Words in a room's name (or subtitle) that put it here; [generic] ones
  /// ("bed") only place a room nothing else has claimed.
  final List<String> keys;
  final List<String> generic;
  final List<Offset> floor;
  final Offset centre;
  final Offset foot;

  /// The label hangs to the left of its stem (else to the right).
  final bool right;
  final List<Offset> screens;

  bool contains(Offset p) {
    var inside = false;
    for (var i = 0, j = floor.length - 1; i < floor.length; j = i++) {
      final a = floor[i], b = floor[j];
      if ((a.dy > p.dy) != (b.dy > p.dy) &&
          p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
        inside = !inside;
      }
    }
    return inside;
  }
}

/// The render's width over its height.
const _blueprintAspect = 1448 / 1086;

const _plots = [
  // The smaller bedroom, top left.
  _Plot(
    keys: ['haam'],
    generic: ['bed'],
    floor: [
      Offset(0.060, 0.050),
      Offset(0.450, 0.045),
      Offset(0.450, 0.410),
      Offset(0.055, 0.415),
    ],
    centre: Offset(0.27, 0.23),
    foot: Offset(0.20, 0.36),
    screens: [Offset(0.105, 0.265)],
  ),
  // The master bedroom, top right.
  _Plot(
    keys: ['m&m', 'master'],
    generic: ['bed'],
    floor: [
      Offset(0.680, 0.050),
      Offset(0.955, 0.045),
      Offset(0.955, 0.550),
      Offset(0.680, 0.545),
    ],
    centre: Offset(0.82, 0.24),
    foot: Offset(0.73, 0.47),
    right: true,
    screens: [Offset(0.905, 0.275)],
  ),
  // The sitting room, bottom left, with the hall.
  _Plot(
    keys: ['sitting', 'living', 'lounge'],
    floor: [
      Offset(0.055, 0.420),
      Offset(0.620, 0.415),
      Offset(0.620, 0.860),
      Offset(0.055, 0.860),
    ],
    centre: Offset(0.33, 0.63),
    foot: Offset(0.19, 0.76),
    screens: [Offset(0.115, 0.635)],
  ),
  // The kitchen, bottom right.
  _Plot(
    keys: ['kitchen'],
    floor: [
      Offset(0.630, 0.600),
      Offset(0.955, 0.600),
      Offset(0.955, 0.920),
      Offset(0.630, 0.900),
    ],
    centre: Offset(0.80, 0.80),
    foot: Offset(0.76, 0.82),
    right: true,
  ),
];

/// Each room's place on the render: the first unclaimed plot a word of its
/// name picks, then the generic words ("bed") for what's left.
Map<int, _Plot> _plotRooms(List<Room> rooms) {
  final plotOf = <int, _Plot>{};
  final used = <_Plot>{};
  String text(Room r) => '${r.name} ${r.subtitle ?? ''}'.toLowerCase();
  for (final pass in [0, 1]) {
    for (final (i, room) in rooms.indexed) {
      if (plotOf.containsKey(i)) continue;
      for (final p in _plots) {
        if (used.contains(p)) continue;
        final words = pass == 0 ? p.keys : p.generic;
        if (words.any(text(room).contains)) {
          plotOf[i] = p;
          used.add(p);
          break;
        }
      }
    }
  }
  return plotOf;
}

/// The home page's house: the apartment render with a glow pooling in each
/// room that has something on (amber for lights, by their level; cyan for
/// an AC cooling; violet on a TV that's on), a label per room hung from a
/// stem — tap a room's floor or its label to open it — and a sideways drag
/// that turns the whole plan in perspective before it springs back. After
/// an interactive 3D "machine" the user sent (stations on a plate with
/// callouts), done with the user's own render instead of a GPU scene:
/// the plan is one texture, so the tilt costs nothing to speak of.
class _HouseView extends StatefulWidget {
  const _HouseView({
    required this.rooms,
    required this.here,
    required this.states,
    required this.width,
    required this.unit,
    required this.night,
    required this.dim,
    required this.onOpen,
    required this.image,
    required this.cards,
  });

  final List<Room> rooms;
  final int here;
  final List<RoomState>? states;
  final double width;
  final double unit;
  final bool night;

  /// After dark: the render is dimmed so it doesn't light the room.
  final bool dim;
  final ValueChanged<int> onOpen;
  final ImageProvider image;

  /// Rooms as cards, for those with no place on the render — and for all
  /// of them when the render can't be loaded (it isn't in the repo).
  final Widget Function(List<int> rooms) cards;

  @override
  State<_HouseView> createState() => _HouseViewState();
}

class _HouseViewState extends State<_HouseView>
    with SingleTickerProviderStateMixin {
  ImageInfo? _info;
  bool _failed = false;
  ImageStream? _stream;
  late final _listener = ImageStreamListener(
    (info, _) {
      if (!mounted) {
        info.dispose();
        return;
      }
      setState(() {
        _info?.dispose();
        _info = info;
      });
    },
    onError: (_, _) {
      if (mounted) setState(() => _failed = true);
    },
  );

  /// How far the plan is turned, −1 (dragged left) to 1: the finger's
  /// while it's down, then springing back to 0.
  final _drag = ValueNotifier(0.0);
  double _released = 0;
  late final _spring = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  static const _curve = ElasticOutCurve(0.7);

  double get _yaw => _spring.isAnimating
      ? _released * (1 - _curve.transform(_spring.value))
      : _drag.value;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(_HouseView old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) _resolve();
  }

  void _resolve() {
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    _info?.dispose();
    _spring.dispose();
    _drag.dispose();
    super.dispose();
  }

  ColorFilter? get _filter {
    if (widget.night) {
      return const ColorFilter.matrix([
        0.42, 0, 0, 0, 0, //
        0, 0.18, 0, 0, 0, //
        0, 0, 0.16, 0, 0, //
        0, 0, 0, 1, 0,
      ]);
    }
    if (widget.dim) {
      return const ColorFilter.matrix([
        0.55, 0, 0, 0, 0, //
        0, 0.55, 0, 0, 0, //
        0, 0, 0.60, 0, 0, //
        0, 0, 0, 1, 0,
      ]);
    }
    return null;
  }

  Matrix4 _matrix(double yaw) => Matrix4.identity()
    ..setEntry(3, 2, -0.0015)
    ..rotateY(yaw * 0.3)
    ..rotateX(yaw.abs() * 0.06);

  @override
  Widget build(BuildContext context) {
    final all = [for (var i = 0; i < widget.rooms.length; i++) i];
    if (_failed) return widget.cards(all);
    final w = widget.width;
    final h = w / _blueprintAspect;
    final u = widget.unit;
    final night = widget.night;
    final amber = _hue(_warm, night);
    final plotOf = _plotRooms(widget.rooms);
    final stem = u * 1.6;
    final glows = <(Offset, double, Color)>[];
    final halos = <(Offset, double, Color)>[];
    final stems = <(Offset, double, Color)>[];
    final labels = <Widget>[];
    Offset at(Offset f) => Offset(f.dx * w, f.dy * h);
    for (final MapEntry(key: i, value: plot) in plotOf.entries) {
      final room = widget.rooms[i];
      final s = widget.states?[i];
      if (s != null) {
        if (s.cooling > 0) {
          halos.add((
            at(plot.centre),
            w * 0.17,
            _hue(_acCool, night).withValues(alpha: 0.45),
          ));
        }
        if (s.lightsOn > 0) {
          glows.add((
            at(plot.centre),
            w * 0.13,
            amber.withValues(alpha: 0.3 + 0.45 * (s.level ?? 100) / 100),
          ));
        }
        if (s.screensOn > 0) {
          for (final p in plot.screens) {
            glows.add((
              at(p),
              w * 0.05,
              _hue(_tvViolet, night).withValues(alpha: 0.7),
            ));
          }
        }
      }
      final foot = at(plot.foot);
      stems.add((foot, stem, amber));
      final lit = s != null && !s.quiet;
      final meta = [
        if (i == widget.here) 'Here',
        s?.line ?? room.summary,
      ].join(' · ');
      labels.add(
        Positioned(
          left: plot.right ? null : foot.dx - u * 0.7,
          right: plot.right ? w - foot.dx - u * 0.7 : null,
          top: foot.dy + stem,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => widget.onOpen(i),
            child: _RoomLabel(
              index: i,
              name: room.name,
              meta: meta,
              locked: room.pin != null && i != widget.here,
              lit: lit,
              hue: amber,
              unit: u,
              maxWidth: w * 0.46,
              night: night,
            ),
          ),
        ),
      );
    }
    final plan = SizedBox(
      width: w,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: _HousePainter(
                  image: _info?.image,
                  filter: _filter,
                  glows: glows,
                  halos: halos,
                  stems: stems,
                  unit: u,
                ),
              ),
            ),
          ),
          ...labels,
        ],
      ),
    );
    final house = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (d) {
        final p = Offset(d.localPosition.dx / w, d.localPosition.dy / h);
        for (final MapEntry(key: i, value: plot) in plotOf.entries) {
          if (plot.contains(p)) {
            widget.onOpen(i);
            return;
          }
        }
      },
      // Sideways only: up and down still scroll the panel.
      onHorizontalDragStart: (_) {
        final yaw = _yaw;
        _spring.stop();
        _drag.value = yaw;
      },
      onHorizontalDragUpdate: (d) =>
          _drag.value = (_drag.value + d.delta.dx / w * 2.4).clamp(-1.0, 1.0),
      onHorizontalDragEnd: (_) {
        _released = _drag.value;
        _spring.forward(from: 0);
        _drag.value = 0;
      },
      child: plan,
    );
    final tilted = AnimatedBuilder(
      animation: Listenable.merge([_spring, _drag]),
      builder: (context, child) => Transform(
        transform: _matrix(_yaw),
        alignment: Alignment.center,
        child: child,
      ),
      child: house,
    );
    final unplotted = [
      for (final i in all)
        if (!plotOf.containsKey(i)) i,
    ];
    if (unplotted.isEmpty) return tilted;
    return Column(
      children: [
        tilted,
        SizedBox(height: u * 0.8),
        widget.cards(unplotted),
      ],
    );
  }
}

/// A room's callout on the house: its number and name (and a lock when it
/// asks for a code), then what's on in it — or what's in it when nothing
/// is. Hangs from a stem at the room's floor, like the station labels in
/// the machine the user sent.
class _RoomLabel extends StatelessWidget {
  const _RoomLabel({
    required this.index,
    required this.name,
    required this.meta,
    required this.locked,
    required this.lit,
    required this.hue,
    required this.unit,
    required this.maxWidth,
    required this.night,
  });

  final int index;
  final String name;
  final String meta;
  final bool locked;
  final bool lit;
  final Color hue;
  final double unit;
  final double maxWidth;
  final bool night;

  @override
  Widget build(BuildContext context) {
    final u = unit;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        padding: EdgeInsets.fromLTRB(u * 0.65, u * 0.45, u * 0.65, u * 0.5),
        decoration: BoxDecoration(
          color: const Color(0xEE14171B),
          borderRadius: BorderRadius.circular(u * 0.55),
          border: Border.all(color: hue.withValues(alpha: lit ? 0.75 : 0.3)),
          boxShadow: [
            BoxShadow(
              color: lit
                  ? hue.withValues(alpha: 0.25)
                  : Colors.black.withValues(alpha: 0.3),
              blurRadius: u * (lit ? 1.4 : 1),
              offset: Offset(0, u * 0.3),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  (index + 1).toString().padLeft(2, '0'),
                  style: TextStyle(
                    color: hue,
                    fontSize: u * 0.56,
                    fontWeight: FontWeight.w500,
                    fontFeatures: const [FontFeature.tabularFigures()],
                    height: 1,
                  ),
                ),
                SizedBox(width: u * 0.5),
                Flexible(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _white.withValues(alpha: night ? 0.8 : 1),
                      fontSize: u * 0.74,
                      fontWeight: FontWeight.w500,
                      height: 1.1,
                    ),
                  ),
                ),
                if (locked) ...[
                  SizedBox(width: u * 0.35),
                  Icon(
                    Icons.lock_rounded,
                    size: u * 0.7,
                    color: _white.withValues(alpha: 0.45),
                  ),
                ],
              ],
            ),
            SizedBox(height: u * 0.3),
            Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: lit ? hue : const Color(0xFF8E939C),
                fontSize: u * 0.56,
                fontWeight: FontWeight.w500,
                height: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The render (dimmed after dark), the rooms' glows and the labels' stems.
class _HousePainter extends CustomPainter {
  _HousePainter({
    required this.image,
    required this.filter,
    required this.glows,
    required this.halos,
    required this.stems,
    required this.unit,
  });

  final ui.Image? image;
  final ColorFilter? filter;

  /// Centre, radius and colour (its alpha is the peak) of each glow.
  final List<(Offset, double, Color)> glows;

  /// The same for the rings round rooms being cooled.
  final List<(Offset, double, Color)> halos;

  /// Foot, length and colour of each label's stem.
  final List<(Offset, double, Color)> stems;
  final double unit;

  @override
  void paint(Canvas canvas, Size size) {
    // A contact shadow under the plan, so it sits on the sky rather than
    // floating in it.
    final ground = Rect.fromCenter(
      center: Offset(size.width * 0.5, size.height * 0.86),
      width: size.width * 1.05,
      height: size.height * 0.5,
    );
    canvas.drawOval(
      ground,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.black.withValues(alpha: 0.55),
            Colors.black.withValues(alpha: 0),
          ],
          stops: const [0.3, 1],
        ).createShader(ground),
    );
    final img = image;
    if (img != null) {
      canvas.drawImageRect(
        img,
        Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
        Offset.zero & size,
        Paint()
          ..colorFilter = filter
          ..filterQuality = FilterQuality.medium,
      );
    }
    for (final (c, r, color) in glows) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [color, color.withValues(alpha: 0)],
            stops: const [0.08, 1],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
    for (final (c, r, color) in halos) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: 0),
              color,
              color.withValues(alpha: 0),
            ],
            stops: const [0.45, 0.78, 1],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
    for (final (foot, length, color) in stems) {
      final end = foot + Offset(0, length);
      canvas.drawLine(
        foot,
        end,
        Paint()
          ..strokeWidth = 1
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: 0.15),
              color.withValues(alpha: 0.85),
            ],
          ).createShader(Rect.fromPoints(foot, end + const Offset(1, 0))),
      );
      canvas.drawCircle(
        foot,
        unit * 0.45,
        Paint()..color = color.withValues(alpha: 0.22),
      );
      canvas.drawCircle(foot, unit * 0.2, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_HousePainter old) =>
      old.image != image ||
      old.filter != filter ||
      old.unit != unit ||
      !listEquals(old.glows, glows) ||
      !listEquals(old.halos, halos) ||
      !listEquals(old.stems, stems);
}

/// The panel's foot (from the user's mock-up): Wi-Fi on the left — green
/// "Connected · Home Wi-Fi", or red "No devices answering" — and on the
/// right "All systems nominal", "Checking devices…" or what's offline.
class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.unit,
    required this.night,
    required this.connected,
    this.offlineLabel = 'No devices answering',
  });

  final double unit;
  final bool night;
  final bool connected;
  final bool checking = false;
  final List<String> down = const [];
  final String offlineLabel;

  @override
  Widget build(BuildContext context) {
    final u = unit;
    final green = _hue(const Color(0xFF34D399), night);
    final amber = _hue(_warm, night);
    final text = _white.withValues(alpha: night ? 0.4 : 0.6);
    final style = TextStyle(
      color: text,
      fontSize: u * 0.72,
      fontWeight: FontWeight.w500,
    );
    Widget item(IconData icon, Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: u * 1.05, color: color),
        SizedBox(width: u * 0.4),
        Flexible(
          child: Text(
            label,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
    return Container(
      padding: EdgeInsets.only(top: u * 0.7),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: _white.withValues(alpha: 0.08))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: connected
                ? item(Icons.wifi_rounded, green, 'Connected · Home Wi-Fi')
                : item(Icons.wifi_off_rounded, _red, offlineLabel),
          ),
          SizedBox(width: u * 0.8),
          Flexible(
            child: checking
                ? item(Icons.sync_rounded, text, 'Checking devices…')
                : down.isEmpty
                ? item(Icons.shield_rounded, amber, 'All systems nominal')
                : item(
                    Icons.warning_amber_rounded,
                    _red,
                    down.length == 1
                        ? '${down.first} offline'
                        : '${down.length} devices offline',
                  ),
          ),
        ],
      ),
    );
  }
}

/// The home page's tally of the whole house: how many lights are on, how
/// many ACs are cooling and how many screens (TVs and boxes) are on. Polls
/// every device every 15 s while the home page is up; "–" until a count
/// is in. A device that doesn't answer counts as off.
class _HomeStats extends StatefulWidget {
  const _HomeStats({
    required this.energy,
    required this.width,
    required this.unit,
    required this.night,
  });

  /// The house-wide poll (every device, every 15 s) — shared with the
  /// energy card, so the house is read once.
  final EnergyTracker energy;
  final double width;
  final double unit;
  final bool night;

  @override
  State<_HomeStats> createState() => _HomeStatsState();
}

class _HomeStatsState extends State<_HomeStats> {
  int? get _lights => widget.energy.lightsOn;
  int? get _cooling => widget.energy.cooling;
  int? get _screens => widget.energy.screensOn;

  @override
  Widget build(BuildContext context) {
    final u = widget.unit;
    final night = widget.night;
    final gap = u * 0.6;
    final tile = (widget.width - 2 * gap) / 3;
    Widget stat(IconData icon, Color hue, int? n, String label) {
      final c = _hue(hue, night);
      final lit = (n ?? 0) > 0;
      return _GlowCard(
        hue: c,
        on: lit,
        unit: u,
        width: tile,
        child: Row(
          children: [
            Icon(
              icon,
              size: u * 1.4,
              color: lit ? c : c.withValues(alpha: 0.5),
            ),
            SizedBox(width: u * 0.5),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    n == null ? '–' : '$n',
                    style: TextStyle(
                      color: _white,
                      fontSize: u * 1.3,
                      fontWeight: FontWeight.w500,
                      height: 1.1,
                    ),
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _white.withValues(alpha: 0.55),
                      fontSize: u * 0.65,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Row(
      children: [
        stat(Icons.lightbulb_rounded, _warm, _lights, 'lights on'),
        SizedBox(width: gap),
        stat(Icons.ac_unit_rounded, _acCool, _cooling, 'cooling'),
        SizedBox(width: gap),
        stat(Icons.tv_rounded, _tvViolet, _screens, 'screens on'),
      ],
    );
  }
}

// ── Energy (lib/energy.dart) ─────────────────────────────────────────────

/// Polls every device in the house every 15 s, whatever's on screen: for
/// the home page's counts (lights on, cooling, screens on) and the energy
/// estimate, which it adds up and saves as it goes.
class EnergyTracker extends ChangeNotifier {
  EnergyTracker(this.rooms, {EnergyMeter? meter})
    : meter =
          meter ??
          EnergyMeter(bills: configuredBills(), billDay: configuredBillDay());

  final List<Room> rooms;
  final EnergyMeter meter;
  final _btu = configuredAcBtu();
  final _baseline = configuredBaseline();
  SharedPreferences? _prefs;
  Timer? _timer;
  bool _loaded = false;

  int? lightsOn, cooling, screensOn;

  /// What's on in each room (by [rooms]' order), for the house view.
  List<RoomState>? roomStates;

  /// Each room's draw now, in watts (by [rooms]' order) — the devices the
  /// dashboard can see; the baseline isn't any room's.
  List<double>? roomWatts;
  Draw? draw;
  DateTime now = DateTime.now();

  /// This billing period's projected bill in MVR, once polled.
  double? get projectedMvr => draw == null
      ? null
      : billMvr(meter.projectedKwh(now), meter.periodDays(now));

  /// The card shows only with bills to go on.
  bool get enabled => meter.bills.isNotEmpty;

  void start() {
    _timer?.cancel();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _poll());
  }

  void stop() => _timer?.cancel();

  static Future<T?> _try<T>(Future<T> f) =>
      f.then<T?>((v) => v).catchError((Object _) => null);

  Future<void> _poll() async {
    if (!_loaded) {
      _loaded = true;
      try {
        _prefs = await SharedPreferences.getInstance();
        meter.load(_prefs!.getString('energy'));
      } catch (_) {}
    }
    final lights = {for (final r in rooms) ...r.lights}.toList();
    final acs = {for (final r in rooms) ...r.acs}.toList();
    final tvs = {for (final r in rooms) ...r.tvs}.toList();
    final boxes = {for (final r in rooms) ...r.boxes}.toList();
    final key = boxes.isEmpty ? null : await _try(_loadAdbKey());
    final ls = await Future.wait([for (final l in lights) _try(l.state())]);
    final as = await Future.wait([for (final a in acs) _try(a.state())]);
    final ts = await Future.wait([for (final t in tvs) _try(t.isOn())]);
    final bs = await Future.wait([
      for (final b in boxes)
        key == null ? Future.value(null) : _try(b.isOn(key)),
    ]);
    var acW = 0.0, lightW = 0.0;
    for (final (i, s) in as.indexed) {
      if (s != null) {
        acW += acWatts(_btu[acs[i].name.toLowerCase()] ?? 12000, s);
      }
    }
    for (final s in ls) {
      if (s != null) lightW += lightWatts(s.on, s.brightness);
    }
    final tvOn = ts.where((on) => on == true).length;
    final boxOn = bs.where((on) => on == true).length;
    lightsOn = ls.where((s) => s?.on == true).length;
    cooling = as.where((s) => s != null && s.on && s.mode <= 2).length;
    screensOn = tvOn + boxOn;
    final lightOf = {for (final (i, l) in lights.indexed) l: ls[i]};
    final acOf = {for (final (i, a) in acs.indexed) a: as[i]};
    final tvOf = {for (final (i, t) in tvs.indexed) t: ts[i]};
    final boxOf = {for (final (i, b) in boxes.indexed) b: bs[i]};
    roomStates = [
      for (final r in rooms)
        RoomState(
          lightsOn: r.lights.where((l) => lightOf[l]?.on == true).length,
          level: r.lights
              .map((l) => lightOf[l])
              .where((s) => s?.on == true)
              .map((s) => s!.brightness ?? 100)
              .fold(null, (int? m, v) => m == null || v > m ? v : m),
          cooling: r.acs.where((a) {
            final s = acOf[a];
            return s != null && s.on && s.mode <= 2;
          }).length,
          screensOn:
              r.tvs.where((t) => tvOf[t] == true).length +
              r.boxes.where((b) => boxOf[b] == true).length,
        ),
    ];
    roomWatts = [
      for (final r in rooms)
        r.acs.fold(0.0, (w, a) {
              final s = acOf[a];
              return s == null
                  ? w
                  : w + acWatts(_btu[a.name.toLowerCase()] ?? 12000, s);
            }) +
            r.lights.fold(0.0, (w, l) {
              final s = lightOf[l];
              return s == null ? w : w + lightWatts(s.on, s.brightness);
            }) +
            r.tvs.where((t) => tvOf[t] == true).length * tvWatts +
            r.boxes.where((b) => boxOf[b] == true).length * boxWatts,
    ];
    now = DateTime.now();
    draw = Draw(
      acs: acW,
      lights: lightW,
      screens: tvOn * tvWatts + boxOn * boxWatts,
      appliances: fridgeWatts + waterHeaterWatts,
      other: max(0, _baseline - fridgeWatts - waterHeaterWatts),
    );
    meter.add(now, draw!);
    _prefs?.setString('energy', meter.toJson());
    notifyListeners();
  }
}

String _kw(double watts) => watts >= 1000
    ? '${(watts / 1000).toStringAsFixed(1)} kW'
    : '${watts.round()} W';

String _mvr(double v) {
  final n = v.round().toString();
  return n.length > 3
      ? '${n.substring(0, n.length - 3)},${n.substring(n.length - 3)}'
      : n;
}

const _months = ['J', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'];
const _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// The home page's energy card: the draw now and its split, today, this
/// billing period and its projected bill, and a line graph of the bills.
class _EnergyCard extends StatefulWidget {
  const _EnergyCard({
    required this.energy,
    required this.width,
    required this.unit,
    required this.night,
  });
  final EnergyTracker energy;
  final double width;
  final double unit;
  final bool night;

  @override
  State<_EnergyCard> createState() => _EnergyCardState();
}

class _EnergyCardState extends State<_EnergyCard> {
  /// The point picked on the graph (touch and drag), or null.
  int? _picked;
  Timer? _unpick;

  @override
  void dispose() {
    _unpick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.unit;
    final night = widget.night;
    final e = widget.energy;
    final m = e.meter;
    final now = e.now;
    final draw = e.draw;
    final amber = _hue(_warm, night);
    final projected = draw == null ? null : m.projectedKwh(now);
    final days = m.periodDays(now);
    final start = m.periodOf(now).$1;

    // The graph: one point per bill, then this period's projection.
    final points = [
      for (final b in m.bills)
        _EnergyPoint(
          b.date,
          b.kwh.toDouble(),
          billMvr(b.kwh.toDouble(), b.days),
          false,
          b.days,
        ),
      if (projected != null)
        _EnergyPoint(
          m.periodOf(now).$2,
          projected,
          billMvr(projected, days),
          true,
          days,
        ),
    ];

    Widget figure(String label, String value, {String? unit}) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: _white.withValues(alpha: 0.55),
              fontSize: u * 0.65,
              fontWeight: FontWeight.w500,
            ),
          ),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(text: value),
                if (unit != null)
                  TextSpan(
                    text: ' $unit',
                    style: TextStyle(
                      fontSize: u * 0.7,
                      fontWeight: FontWeight.w500,
                      color: _white.withValues(alpha: 0.6),
                    ),
                  ),
              ],
            ),
            maxLines: 1,
            style: TextStyle(
              color: _white,
              fontSize: u * 1.15,
              fontWeight: FontWeight.w500,
              height: 1.2,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );

    Widget part(Color c, String label, double w) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: u * 0.5,
          height: u * 0.5,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hue(c, night),
          ),
        ),
        SizedBox(width: u * 0.3),
        Text(
          '$label ${_kw(w)}',
          style: TextStyle(
            color: _white.withValues(alpha: 0.7),
            fontSize: u * 0.62,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );

    final picked = _picked == null ? null : points[_picked!];

    return _GlowCard(
      hue: amber,
      on: false,
      unit: u,
      width: widget.width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: u * 2.4,
                height: u * 2.4,
                decoration: BoxDecoration(
                  color: amber.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(u * 0.7),
                ),
                child: Icon(Icons.bolt_rounded, size: u * 1.5, color: amber),
              ),
              SizedBox(width: u * 0.7),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'ENERGY',
                      style: TextStyle(
                        color: _white,
                        fontSize: u * 0.8,
                        fontWeight: FontWeight.w500,
                        letterSpacing: u * 0.15,
                      ),
                    ),
                    Text(
                      'Estimate · bill from ${start.day} ${_monthNames[start.month - 1]}',
                      style: TextStyle(
                        color: _white.withValues(alpha: 0.5),
                        fontSize: u * 0.62,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    draw == null ? '–' : _kw(draw.total),
                    style: TextStyle(
                      color: _white,
                      fontSize: u * 1.5,
                      fontWeight: FontWeight.w500,
                      height: 1.1,
                    ),
                  ),
                  Text(
                    'now',
                    style: TextStyle(
                      color: _white.withValues(alpha: 0.5),
                      fontSize: u * 0.62,
                    ),
                  ),
                ],
              ),
            ],
          ),
          SizedBox(height: u * 0.9),
          Row(
            children: [
              figure(
                'Today',
                draw == null ? '–' : m.dayKwh.toStringAsFixed(1),
                unit: 'kWh',
              ),
              figure(
                'This bill',
                draw == null ? '–' : m.periodKwh.round().toString(),
                unit: 'kWh',
              ),
              figure(
                'Projected',
                projected == null ? '–' : _mvr(billMvr(projected, days)),
                unit: 'MVR',
              ),
            ],
          ),
          SizedBox(height: u * 0.9),
          // The graph, with the picked point's reading over it.
          SizedBox(
            height: u * 1.2,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                picked == null
                    ? 'kWh a day, per bill · touch for details'
                    : '${picked.projected ? 'This bill (projected)' : '${picked.date.day} ${_monthNames[picked.date.month - 1]} bill'}'
                          ' · ${picked.perDay.toStringAsFixed(1)} kWh/day'
                          ' · ${_mvr(picked.kwh)} kWh · MVR ${_mvr(picked.mvr)}',
                style: TextStyle(
                  color: _white.withValues(alpha: picked == null ? 0.45 : 0.85),
                  fontSize: u * 0.62,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              void pick(Offset p) {
                final xs = _EnergyChartPainter.xs(points, w, u);
                var best = 0;
                for (var i = 1; i < xs.length; i++) {
                  if ((xs[i] - p.dx).abs() < (xs[best] - p.dx).abs()) best = i;
                }
                _unpick?.cancel();
                if (best != _picked) HapticFeedback.selectionClick();
                setState(() => _picked = best);
              }

              void release() {
                _unpick?.cancel();
                _unpick = Timer(const Duration(seconds: 4), () {
                  if (mounted) setState(() => _picked = null);
                });
              }

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => pick(d.localPosition),
                onTapUp: (_) => release(),
                onHorizontalDragUpdate: (d) => pick(d.localPosition),
                onHorizontalDragEnd: (_) => release(),
                child: CustomPaint(
                  size: Size(w, u * 7),
                  painter: _EnergyChartPainter(
                    points: points,
                    hue: amber,
                    unit: u,
                    picked: _picked,
                  ),
                ),
              );
            },
          ),
          if (draw != null) ...[
            SizedBox(height: u * 0.7),
            Wrap(
              spacing: u * 0.9,
              runSpacing: u * 0.3,
              children: [
                part(_acCool, 'ACs', draw.acs),
                part(_warm, 'Lights', draw.lights),
                part(_tvViolet, 'Screens', draw.screens),
                part(_gold, 'Fridge & heater', draw.appliances),
                part(const Color(0xFF9AA0AA), 'Other', draw.other),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _EnergyPoint {
  const _EnergyPoint(this.date, this.kwh, this.mvr, this.projected, this.days);

  /// The bill's date (for the projection, the period's end).
  final DateTime date;
  final double kwh, mvr;
  final bool projected;
  final int days;

  /// What the graph plots: bills run 12 to 33 days, so kWh a day compares.
  double get perDay => kwh / max(1, days);
}

/// A grid step giving about three lines over [range].
double _niceStep(double range) {
  for (final s in const [
    1.0,
    2.0,
    5.0,
    10.0,
    20.0,
    50.0,
    100.0,
    200.0,
    500.0,
  ]) {
    if (range / s <= 3.5) return s;
  }
  return 1000;
}

/// The bills as a line: a smooth 2 px curve over a soft fill, faint grid
/// lines with their kWh at the left, month initials along the foot. A gap
/// of more than ~45 days between bills breaks the line (no made-up months);
/// the projection is a hollow glowing point, joined only if it follows on.
class _EnergyChartPainter extends CustomPainter {
  _EnergyChartPainter({
    required this.points,
    required this.hue,
    required this.unit,
    this.picked,
  });

  final List<_EnergyPoint> points;
  final Color hue;
  final double unit;
  final int? picked;

  static double left(double u) => u * 2.2;

  /// Each point's x: evenly spaced, with an extra step before a gap.
  static List<double> xs(List<_EnergyPoint> points, double w, double u) {
    if (points.isEmpty) return [];
    final steps = <double>[0];
    for (var i = 1; i < points.length; i++) {
      final gap = points[i].date.difference(points[i - 1].date).inDays > 45;
      steps.add(steps.last + (gap ? 1.6 : 1));
    }
    final span = max(1.0, steps.last);
    final l = left(u) + u * 0.4, r = w - u * 0.6;
    return [for (final s in steps) l + (r - l) * s / span];
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;
    final u = unit;
    final top = u * 0.6, bottom = size.height - u * 1.2;
    final hi = points.map((p) => p.perDay).reduce(max);
    final lo = points.map((p) => p.perDay).reduce(min);
    // A round scale around the data, about three grid lines.
    final step = _niceStep(max(1, hi - lo));
    final yMin = max(0.0, (lo / step).floor() * step);
    final yMax = max(yMin + step, (hi / step).ceil() * step);
    double y(double v) => bottom - (v - yMin) / (yMax - yMin) * (bottom - top);
    final xs = _EnergyChartPainter.xs(points, size.width, u);

    // Grid and its labels, recessive.
    final grid = Paint()
      ..color = _white.withValues(alpha: 0.08)
      ..strokeWidth = 1;
    for (var v = yMin; v <= yMax + step / 2; v += step) {
      final gy = y(v);
      canvas.drawLine(Offset(left(u), gy), Offset(size.width, gy), grid);
      final tp = TextPainter(
        text: TextSpan(
          text: v.round().toString(),
          style: TextStyle(
            fontFamily: 'Inter',
            color: _white.withValues(alpha: 0.4),
            fontSize: u * 0.55,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(0, gy - tp.height / 2));
    }

    // Runs of bills without a gap, each a smooth curve over a fill.
    final runs = <List<int>>[[]];
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final breaks =
          i > 0 &&
          (p.date.difference(points[i - 1].date).inDays > 45 || p.projected);
      if (breaks && runs.last.isNotEmpty) runs.add([]);
      runs.last.add(i);
    }
    for (final run in runs) {
      if (run.isEmpty || points[run.first].projected) continue;
      final pts = [for (final i in run) Offset(xs[i], y(points[i].perDay))];
      final line = Path()..moveTo(pts.first.dx, pts.first.dy);
      for (var i = 1; i < pts.length; i++) {
        // A gentle curve: control points a third of the way along, level.
        final a = pts[i - 1], b = pts[i];
        final dx = (b.dx - a.dx) / 3;
        line.cubicTo(a.dx + dx, a.dy, b.dx - dx, b.dy, b.dx, b.dy);
      }
      final fill = Path.from(line)
        ..lineTo(pts.last.dx, bottom)
        ..lineTo(pts.first.dx, bottom)
        ..close();
      canvas.drawPath(
        fill,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [hue.withValues(alpha: 0.28), hue.withValues(alpha: 0)],
          ).createShader(Rect.fromLTRB(0, top, size.width, bottom)),
      );
      canvas.drawPath(
        line,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = hue,
      );
      if (pts.length == 1) {
        canvas.drawCircle(pts.first, 3, Paint()..color = hue);
      }
    }

    // The latest bill and the projection get points (and the projection a
    // dashed link if it follows straight on); the picked one a guide.
    for (var i = 0; i < points.length; i++) {
      final p = points[i];
      final c = Offset(xs[i], y(p.perDay));
      if (p.projected) {
        final prev = i > 0 ? points[i - 1] : null;
        if (prev != null && p.date.difference(prev.date).inDays <= 45) {
          final a = Offset(xs[i - 1], y(prev.perDay));
          final dash = Paint()
            ..color = hue.withValues(alpha: 0.7)
            ..strokeWidth = 2;
          final n = ((c - a).distance / 6).floor();
          for (var k = 0; k < n; k += 2) {
            canvas.drawLine(
              Offset.lerp(a, c, k / n)!,
              Offset.lerp(a, c, (k + 1) / n)!,
              dash,
            );
          }
        }
        canvas.drawCircle(
          c,
          u * 0.9,
          Paint()..color = hue.withValues(alpha: 0.18),
        );
        canvas.drawCircle(
          c,
          u * 0.38,
          Paint()..color = const Color(0xFF15171C),
        );
        canvas.drawCircle(
          c,
          u * 0.38,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = hue,
        );
      } else if (i == picked) {
        canvas.drawCircle(
          c,
          u * 0.42,
          Paint()..color = const Color(0xFF15171C),
        );
        canvas.drawCircle(c, u * 0.3, Paint()..color = hue);
      }
      if (i == picked) {
        canvas.drawLine(
          Offset(c.dx, top),
          Offset(c.dx, bottom),
          Paint()
            ..color = _white.withValues(alpha: 0.3)
            ..strokeWidth = 1,
        );
      }
      // Month initial along the foot ("now" under the projection).
      final tp = TextPainter(
        text: TextSpan(
          // The bill's month (3 letters when there's room).
          text: p.projected
              ? 'now'
              : points.length <= 8
              ? _monthNames[p.date.month - 1]
              : _months[p.date.month - 1],
          style: TextStyle(
            fontFamily: 'Inter',
            color: _white.withValues(
              alpha: i == picked || p.projected ? 0.85 : 0.4,
            ),
            fontSize: u * 0.55,
            fontWeight: p.projected ? FontWeight.w500 : FontWeight.w400,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(c.dx - tp.width / 2, bottom + u * 0.35));
    }
  }

  @override
  bool shouldRepaint(_EnergyChartPainter old) =>
      old.points.length != points.length ||
      old.picked != picked ||
      old.hue != hue ||
      (points.isNotEmpty && old.points.last.kwh != points.last.kwh);
}

/// The home page's foot: the same status bar, with Wi-Fi read from the
/// phone's own network (no device is polled on the home page) — checked
/// on open and every 30 s.
class _HomeStatus extends StatefulWidget {
  const _HomeStatus({required this.unit, required this.night});
  final double unit;
  final bool night;

  @override
  State<_HomeStatus> createState() => _HomeStatusState();
}

class _HomeStatusState extends State<_HomeStatus> {
  bool _connected = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _check();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _check());
  }

  Future<void> _check() async {
    var ok = false;
    try {
      final all = await NetworkInterface.list(type: InternetAddressType.IPv4);
      ok = all.any((i) => i.addresses.any((a) => !a.isLoopback));
    } on Object {
      ok = false;
    }
    if (mounted && ok != _connected) setState(() => _connected = ok);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _StatusBar(
    unit: widget.unit,
    night: widget.night,
    connected: _connected,
    offlineLabel: 'No Wi-Fi',
  );
}

/// A locked room's passcode pad, in the panel's place: four dots and a
/// keypad. The right code opens the room; a wrong one flashes the dots red
/// and clears. The house icon goes back to the home page.
class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    required this.room,
    required this.width,
    required this.unit,
    required this.onCancel,
    required this.onUnlock,
    this.night = false,
  });

  final Room room;
  final double width;
  final double unit;
  final bool night;
  final VoidCallback onCancel;
  final VoidCallback onUnlock;

  @override
  State<PinPad> createState() => _PinPadState();
}

class _PinPadState extends State<PinPad> {
  String _typed = '';
  bool _wrong = false;

  void _press(String key) {
    if (_wrong) return;
    final pin = widget.room.pin ?? '';
    setState(() {
      if (key == '<') {
        if (_typed.isNotEmpty) _typed = _typed.substring(0, _typed.length - 1);
        return;
      }
      _typed += key;
    });
    if (_typed.length < pin.length) return;
    if (_typed == pin) {
      widget.onUnlock();
      return;
    }
    setState(() => _wrong = true);
    Timer(const Duration(milliseconds: 700), () {
      if (mounted) {
        setState(() {
          _wrong = false;
          _typed = '';
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.unit;
    final night = widget.night;
    final amber = _hue(_warm, night);
    final red = _hue(_red, night);
    final length = max(1, widget.room.pin?.length ?? 4);
    final pad = u * 1.1; // _GlowCard's own padding
    final gap = u * 0.6;
    final keyW = (widget.width - pad * 2 - gap * 2) / 3;
    final keyH = u * 2.8;

    Widget key(String label) {
      if (label.isEmpty) return SizedBox(width: keyW, height: keyH);
      final back = label == '<';
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _press(label),
        child: Container(
          width: keyW,
          height: keyH,
          alignment: Alignment.center,
          decoration: back
              ? null
              : BoxDecoration(
                  color: _white.withValues(alpha: 0.07),
                  border: Border.all(color: _surfaceEdge),
                  borderRadius: BorderRadius.circular(u * 0.9),
                ),
          child: back
              ? Icon(
                  Icons.backspace_outlined,
                  size: u * 1.2,
                  color: _white.withValues(alpha: 0.6),
                )
              : Text(
                  label,
                  style: TextStyle(
                    color: _white.withValues(alpha: night ? 0.7 : 0.92),
                    fontSize: u * 1.2,
                    fontWeight: FontWeight.w500,
                  ),
                ),
        ),
      );
    }

    Widget row(List<String> keys) => Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [for (final k in keys) key(k)],
    );

    return SizedBox(
      width: widget.width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelHeader(
            unit: u,
            night: night,
            title: widget.room.name,
            subtitle: _wrong ? 'Wrong passcode' : 'Enter passcode',
            icon: Icons.home_rounded,
            onTap: widget.onCancel,
          ),
          SizedBox(height: u * 0.8),
          _GlowCard(
            hue: _wrong ? red : amber,
            on: false,
            alert: _wrong,
            unit: u,
            width: widget.width,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < length; i++)
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        margin: EdgeInsets.symmetric(horizontal: u * 0.45),
                        width: u * 0.9,
                        height: u * 0.9,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _wrong
                              ? red
                              : i < _typed.length
                              ? amber
                              : Colors.transparent,
                          border: Border.all(
                            color: _wrong ? red : amber.withValues(alpha: 0.6),
                            width: u * 0.12,
                          ),
                        ),
                      ),
                  ],
                ),
                SizedBox(height: u * 1.2),
                row(['1', '2', '3']),
                SizedBox(height: gap),
                row(['4', '5', '6']),
                SizedBox(height: gap),
                row(['7', '8', '9']),
                SizedBox(height: gap),
                row(['', '0', '<']),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The panel's header: an icon in a rounded square (a button when [onTap]
/// is set), a spaced-caps title with a line under it, and [trailing].
class _PanelHeader extends StatelessWidget {
  const _PanelHeader({
    required this.unit,
    required this.night,
    required this.title,
    required this.icon,
    this.subtitle,
    this.onTap,
  });

  final double unit;
  final bool night;
  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  final List<Widget> trailing = const [];

  @override
  Widget build(BuildContext context) {
    final u = unit;
    return Row(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: u * 2.8,
            height: u * 2.8,
            decoration: BoxDecoration(
              color: _white.withValues(alpha: 0.07),
              border: Border.all(color: _surfaceEdge),
              borderRadius: BorderRadius.circular(u * 0.8),
            ),
            child: Icon(icon, size: u * 1.4, color: _hue(_warm, night)),
          ),
        ),
        SizedBox(width: u * 0.7),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _white.withValues(alpha: night ? 0.55 : 0.8),
                  fontSize: u * 0.8,
                  fontWeight: FontWeight.w500,
                  letterSpacing: u * 0.2,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _white.withValues(alpha: night ? 0.4 : 0.55),
                    fontSize: u * 0.7,
                    fontWeight: FontWeight.w500,
                  ),
                ),
            ],
          ),
        ),
        ...trailing,
      ],
    );
  }
}

class LightsPanel extends StatefulWidget {
  const LightsPanel({
    super.key,
    this.title,
    this.subtitle,
    this.onHome,
    required this.lights,
    required this.width,
    required this.unit,
    this.acs = const [],
    this.tvs = const [],
    this.boxes = const [],
    this.switches = const [],
    this.night = false,
  });

  /// The room's name (null: the one-room "ROOM DASHBOARD" of old) and
  /// what it's also called.
  final String? title;
  final String? subtitle;

  /// Back to the home page — the header's house icon. Null with one room.
  final VoidCallback? onHome;

  final List<Light> lights;
  final double width;

  /// The air conditioners, two tiles to a row under the lights.
  final List<GreeAc> acs;

  /// The TV and its set-top box share one wide card under the AC tiles.
  final List<HisenseTv> tvs;
  final List<AndroidTvBox> boxes;

  /// Sonoff wall switches: fans on one row, lights three to a row.
  final List<SonoffSwitch> switches;

  /// Base text size; the tiles are proportioned off it.
  final double unit;

  /// Night mode: every colour shifts to deep red.
  final bool night;

  @override
  State<LightsPanel> createState() => _LightsPanelState();
}

class _LightsPanelState extends State<LightsPanel> with WidgetsBindingObserver {
  final _states = <Light, LightState>{};
  final _offline = <Light>{};
  final _acOffline = <GreeAc>{};
  final _busy = <Light>{};
  final _tvOn = <HisenseTv, bool>{};
  final _tvSource = <HisenseTv, String?>{};

  /// The set-top box: on/off, or why it can't say ("Allow on TV" while the
  /// box's debugging prompt waits for the user, "Offline").
  final _boxOn = <AndroidTvBox, bool>{};
  final _boxProblem = <AndroidTvBox, String>{};
  final _boxSwitched = <AndroidTvBox, DateTime>{};

  /// When a TV was last switched. Its broker takes a few seconds to go
  /// down (or come up), so polls inside [_tvSettle] would undo the tap.
  final _tvSwitched = <HisenseTv, DateTime>{};
  static const _tvSettle = Duration(seconds: 20);

  /// The boxes playing through each TV's HDMI (MEDIA_BOX), for OK.
  static final _mediaBoxes = configuredMediaBoxes();

  /// How long a box gets to boot after a Wake-on-LAN before a poll may
  /// read it as off again.
  static const _bootTime = Duration(seconds: 45);
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    for (final box in widget.boxes) {
      box.onWaiting = () {
        if (mounted) setState(() {});
      };
    }
    _startPolling();
  }

  void _startPolling() {
    _poll?.cancel();
    _refreshAll();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _refreshAll());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _poll?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    _acNudge.dispose();
    super.dispose();
  }

  void _refreshAll() {
    for (final light in widget.lights) {
      if (!_busy.contains(light)) _refresh(light);
    }
    for (final tv in widget.tvs) {
      _refreshTv(tv);
    }
    for (final box in widget.boxes) {
      _refreshBox(box);
    }
  }

  Future<void> _refreshBox(AndroidTvBox box) async {
    final switched = _boxSwitched[box];
    final now = DateTime.now();
    if (switched != null &&
        now.difference(switched) < const Duration(seconds: 6)) {
      return;
    }
    // Booting after a Wake-on-LAN: off the network until it's up.
    final woke = box.wokeAt;
    if (woke != null && now.difference(woke) < _bootTime) return;
    try {
      final on = await box.isOn(await _loadAdbKey());
      if (!mounted) return;
      setState(() {
        _boxOn[box] = on;
        _boxProblem.remove(box);
      });
      if (woke != null) {
        box.wokeAt = null;
        // Its boot time is up and it's still not there: the magic packet
        // didn't reach it, or it can't wake on LAN.
        if (!on) _flashBoxProblem(box, "Didn't wake — use the remote");
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _boxProblem[box] = e.toString().contains('Allow')
              ? 'Allow on TV'
              : 'Offline',
        );
      }
    }
  }

  Future<void> _toggleBox(AndroidTvBox box) async {
    final on = !(_boxOn[box] ?? false);
    setState(() {
      _boxOn[box] = on;
      _boxSwitched[box] = DateTime.now();
    });
    try {
      await box.setPower(await _loadAdbKey(), on);
    } catch (_) {
      _boxSwitched.remove(box);
      if (on && !box.canWake) {
        // Asleep and off the network: only its remote wakes it.
        setState(() => _boxOn[box] = false);
        _flashBoxProblem(box, 'Use the remote to turn on');
        return;
      }
      _refreshBox(box);
    }
  }

  /// Shows [text] under the box's button for 4 s.
  void _flashBoxProblem(AndroidTvBox box, String text) {
    if (!mounted) return;
    setState(() => _boxProblem[box] = text);
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted && _boxProblem[box] == text) {
        setState(() => _boxProblem.remove(box));
      }
    });
  }

  Future<void> _refreshTv(HisenseTv tv) async {
    final switched = _tvSwitched[tv];
    if (switched != null && DateTime.now().difference(switched) < _tvSettle) {
      return;
    }
    final on = await tv.isOn();
    String? source;
    if (on) {
      try {
        source = await tv.source();
      } catch (_) {
        // Fine — the card just doesn't name the input.
      }
    }
    if (mounted) {
      setState(() {
        _tvOn[tv] = on;
        _tvSource[tv] = source;
      });
    }
  }

  Future<void> _toggleTv(HisenseTv tv) async {
    final on = !(_tvOn[tv] ?? false);
    setState(() {
      _tvOn[tv] = on;
      _tvSwitched[tv] = DateTime.now();
    });
    try {
      await tv.setPower(on);
    } catch (_) {
      // Unreachable: let the next poll show what it really is.
      _tvSwitched.remove(tv);
      _refreshTv(tv);
    }
  }

  Future<void> _refresh(Light light) async {
    try {
      final state = await light.state();
      if (mounted) {
        setState(() {
          _states[light] = state;
          _offline.remove(light);
        });
      }
    } catch (_) {
      if (mounted) setState(() => _offline.add(light));
    }
  }

  /// Sends [action], shows [expected] straight away if it went through, then
  /// reads the bulb back to confirm.
  Future<void> _run(
    Light light,
    Future<void> Function() action,
    LightState expected,
  ) async {
    setState(() => _busy.add(light));
    try {
      await action();
      // Keep the colour temperature through on / off / dimming.
      _states[light] = LightState(
        expected.on,
        expected.brightness,
        expected.kelvin ?? _states[light]?.kelvin,
      );
      _offline.remove(light);
    } catch (_) {
      _offline.add(light);
    }
    if (!mounted) return;
    setState(() => _busy.remove(light));
    _refresh(light);
  }

  /// Which scene button is running: 'gn', 'gm', or null.
  String? _scene;

  /// Bumped after a scene changes an AC, so its tile re-reads the unit
  /// straight away instead of at its next 15 s poll.
  final _acNudge = ValueNotifier<int>(0);

  /// GN (good night): White Light off, Warm Light on at 1%, Bedroom AC on
  /// at 24°. GM (good morning): Bedroom AC off, Warm Light 100%, White
  /// Light on. Everything at once; a device that fails is just skipped —
  /// its tile shows Offline as usual.
  /// Whether this room has any of the scenes' devices (see [_runScene]).
  bool get _hasScenes =>
      widget.lights.any((l) {
        final n = l.name.toLowerCase();
        return n.contains('white') || n.contains('warm');
      }) ||
      widget.acs.any((a) => a.name.toLowerCase() == 'bedroom');

  Future<void> _runScene(bool goodNight) async {
    Light? light(String word) => widget.lights
        .where((l) => l.name.toLowerCase().contains(word))
        .firstOrNull;
    final white = light('white');
    final warm = light('warm');
    final ac =
        widget.acs
            .where((a) => a.name.toLowerCase() == 'bedroom')
            .firstOrNull ??
        widget.acs.firstOrNull;
    setState(() => _scene = goodNight ? 'gn' : 'gm');
    Future<void> acJob(Future<void> Function(GreeAc ac) job) async {
      if (ac == null) return;
      try {
        await job(ac);
      } catch (_) {
        // The AC tile will show it's unreachable.
      }
    }

    await Future.wait([
      if (goodNight) ...[
        if (white != null)
          _run(
            white,
            () => white.setPower(false),
            LightState(false, _states[white]?.brightness),
          ),
        if (warm != null)
          _run(warm, () => warm.setBrightness(1), const LightState(true, 1)),
        acJob((ac) async {
          await ac.setPower(true);
          await ac.setTemp(24);
        }),
      ] else ...[
        acJob((ac) => ac.setPower(false)),
        if (warm != null)
          _run(
            warm,
            () => warm.setBrightness(100),
            const LightState(true, 100),
          ),
        if (white != null)
          _run(
            white,
            () => white.setPower(true),
            LightState(true, _states[white]?.brightness),
          ),
      ],
    ]);
    _acNudge.value++;
    if (mounted) setState(() => _scene = null);
  }

  /// The light the dimmer row works on: the last tile tapped, or its name
  /// in the row tapped to move to the next (the user, 10 Nov 2026).
  Light? _dimTarget;

  /// Mock-up pixels to this panel's size (unit is 0.034 of the short side;
  /// the mock-up was drawn 411 wide).
  double get _s => widget.unit / (411 * 0.034);

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final gap = 10 * s;
    final gold = _goldFor(widget.night);
    final half = (widget.width - 12 * s) / 2;
    final third = (widget.width - 2 * 8 * s) / 3;
    final empty =
        widget.lights.isEmpty &&
        widget.acs.isEmpty &&
        widget.tvs.isEmpty &&
        widget.boxes.isEmpty &&
        widget.switches.isEmpty;
    // Scenes, as text — only in the room that has their devices.
    Widget scene(String label, IconData icon, bool goodNight) =>
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _scene == null ? () => _runScene(goodNight) : null,
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 300),
            opacity: _scene == null ? 1 : 0.4,
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 8 * s),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 12 * s, color: goodNight ? _muted : gold),
                  SizedBox(width: 6 * s),
                  Text(
                    label,
                    style: _caps(
                      10 * s,
                      color: goodNight ? _muted : gold,
                      spacing: 0.25,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    return SizedBox(
      width: widget.width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Lights first: the user uses them most, then the AC, then TV.
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.lights.isNotEmpty ? 'LIGHTS' : '',
                  style: _caps(9.5 * s, spacing: 0.32),
                ),
              ),
              if (_hasScenes) ...[
                scene('NIGHT', Icons.bedtime_outlined, true),
                SizedBox(width: 18 * s),
                scene('MORNING', Icons.wb_sunny_outlined, false),
              ],
            ],
          ),
          if (empty)
            Padding(
              padding: EdgeInsets.only(top: gap),
              child: Text(
                'NOTHING TO CONTROL HERE YET',
                style: _caps(10 * s, spacing: 0.3),
              ),
            ),
          SizedBox(height: 4 * s),
          Wrap(
            spacing: 12 * s,
            runSpacing: 12 * s,
            children: [for (final light in widget.lights) _tile(light, half)],
          ),
          if (widget.lights.any((l) => l.dimmable)) ...[
            SizedBox(height: gap),
            _dimmerRow(),
          ],
          if (widget.switches.isNotEmpty) ...[
            SizedBox(height: gap),
            Wrap(
              spacing: 8 * s,
              runSpacing: 8 * s,
              children: [
                for (final sw in [
                  ...widget.switches.where((s) => s.isFan),
                  ...widget.switches.where((s) => !s.isFan),
                ])
                  _switchTile(sw, third),
              ],
            ),
          ],
          for (final ac in widget.acs) ...[
            SizedBox(height: 12 * s),
            AcPanel(
              ac: ac,
              wide: true,
              width: widget.width,
              unit: widget.unit,
              night: widget.night,
              nudge: _acNudge,
              onOffline: (off) => setState(
                () => off ? _acOffline.add(ac) : _acOffline.remove(ac),
              ),
            ),
          ],
          if (widget.tvs.isNotEmpty || widget.boxes.isNotEmpty) ...[
            SizedBox(height: gap),
            _tvCard(widget.tvs.firstOrNull, widget.boxes.firstOrNull),
          ],
          SizedBox(height: gap),
        ],
      ),
    );
  }

  /// A light: a big tile — the icon, its name and state. Tapping it turns
  /// it on or off and makes it the dimmer row's light; one with a colour
  /// temperature (the Yeelight) opens its sheet on press and hold.
  Widget _tile(Light light, double width) {
    final s = _s;
    final state = _states[light];
    final on = state?.on == true;
    final level = state?.brightness;
    final offline = _offline.contains(light);
    final busy = _busy.contains(light);
    final gold = _goldFor(widget.night);
    final lit = on && !offline;
    final status = offline
        ? 'OFFLINE'
        : state == null
        ? 'CONNECTING'
        : on
        ? (light.dimmable && level != null ? 'ON  ·  $level%' : 'ON')
        : 'OFF';
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (light.dimmable) setState(() => _dimTarget = light);
        if (busy || state == null) return;
        _run(
          light,
          () => light.setPower(!on),
          LightState(!on, level, state.kelvin),
        );
      },
      onLongPress: light.hasKelvin && state != null
          ? () => _openKelvin(light)
          : null,
      child: _LuxCard(
        width: width,
        height: 108 * s,
        radius: 20 * s,
        lit: lit ? gold : null,
        alert: offline,
        padding: EdgeInsets.fromLTRB(18 * s, 16 * s, 16 * s, 14 * s),
        child: Stack(
          children: [
            if (lit) Positioned(top: 0, right: 0, child: _luxDot(gold, 5 * s)),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                HugeIcon(
                  icon: HugeIcons.strokeRoundedBulb,
                  size: 26 * s,
                  color: lit ? gold : _muted,
                  strokeWidth: 1.2,
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      light.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _ivory,
                        fontSize: 15 * s,
                        fontWeight: FontWeight.w400,
                        height: 1.2,
                      ),
                    ),
                    SizedBox(height: 4 * s),
                    Text(
                      status,
                      style: _caps(
                        9.5 * s,
                        color: offline
                            ? _red
                            : lit
                            ? gold
                            : _muted,
                        spacing: 0.26,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The dimmer row: the light's name in gold (tap it to move to the next
  /// dimmable light) and 1 · 25 · 50 · 100, the nearest one to its level
  /// underlined in gold. A level turns the light on.
  Widget _dimmerRow() {
    final s = _s;
    final gold = _goldFor(widget.night);
    final dimmable = widget.lights.where((l) => l.dimmable).toList();
    var target = _dimTarget;
    if (target == null || !dimmable.contains(target)) {
      target = dimmable.firstWhere(
        (l) => _states[l]?.on == true,
        orElse: () => dimmable.first,
      );
    }
    final light = target;
    final state = _states[light];
    final on = state?.on == true;
    final level = state?.brightness;
    final busy = _busy.contains(light);
    final nearest = level == null
        ? null
        : _presets.reduce(
            (a, b) => (a - level).abs() <= (b - level).abs() ? a : b,
          );
    return _LuxCard(
      height: 46 * s,
      radius: 23 * s,
      padding: EdgeInsets.only(left: 18 * s, right: 6 * s),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: dimmable.length < 2
                  ? null
                  : () => setState(
                      () => _dimTarget =
                          dimmable[(dimmable.indexOf(light) + 1) %
                              dimmable.length],
                    ),
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      light.name.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _caps(9.5 * s, color: gold, spacing: 0.3),
                    ),
                  ),
                  if (dimmable.length > 1) ...[
                    SizedBox(width: 4 * s),
                    Icon(
                      Icons.unfold_more_rounded,
                      size: 13 * s,
                      color: _muted,
                    ),
                  ],
                ],
              ),
            ),
          ),
          for (final pct in _presets)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: busy || state == null
                  ? null
                  : () => _run(
                      light,
                      () => light.setBrightness(pct),
                      LightState(true, pct, state.kelvin),
                    ),
              child: SizedBox(
                width: (pct == 100 ? 52 : 44) * s,
                height: 44 * s,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '$pct',
                      style: TextStyle(
                        color: on && pct == nearest ? _ivory : _muted,
                        fontSize: 13 * s,
                        fontWeight: on && pct == nearest
                            ? FontWeight.w400
                            : FontWeight.w300,
                        letterSpacing: s,
                      ),
                    ),
                    SizedBox(height: 5 * s),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 300),
                      width: 18 * s,
                      height: 1,
                      decoration: BoxDecoration(
                        color: on && pct == nearest ? gold : Colors.transparent,
                        boxShadow: on && pct == nearest
                            ? [BoxShadow(color: gold, blurRadius: 6 * s)]
                            : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// The colour-temperature sheet (press and hold the White Light's box):
  /// a big warm → cool slider and the presets, over the room.
  Future<void> _openKelvin(Light light) async {
    HapticFeedback.mediumImpact();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      isScrollControlled: true,
      builder: (_) => _KelvinSheet(
        light: light,
        unit: widget.unit,
        night: widget.night,
        state: _states[light] ?? const LightState(false),
        onState: (s) {
          if (mounted) setState(() => _states[light] = s);
        },
      ),
    );
    _refresh(light);
  }

  /// A switch's name without its room's prefix: "Haam's Ceiling 1" reads
  /// "Ceiling 1" in Haam's Room, "Kitchen Fan" reads "Fan" in the Kitchen.
  /// (Names are unique across the house; the prefix just repeats the room.)
  String _shortName(String name) {
    final room = (widget.title ?? '').split(' ').first.toLowerCase();
    if (room.isEmpty || !name.toLowerCase().startsWith('$room ')) return name;
    return name.substring(room.length + 1);
  }

  /// A Sonoff switch: a small tile with its icon and name. Not wired up yet
  /// — greyed, and a tap does nothing.
  Widget _switchTile(SonoffSwitch sw, double width) {
    final s = _s;
    final n = sw.name.toLowerCase();
    // Hugeicons, picked by the user's naming.
    final icon = sw.isFan
        ? HugeIcons.strokeRoundedFan01
        : n.contains('wall')
        ? HugeIcons.strokeRoundedLampWallDown
        : n.contains('cabinet')
        ? HugeIcons.strokeRoundedCabinet01
        : n.contains('hanging')
        ? HugeIcons.strokeRoundedLamp02
        : n.contains('ceiling')
        ? HugeIcons.strokeRoundedLampCeiling
        : HugeIcons.strokeRoundedBulb;
    return Opacity(
      opacity: sw.isSetUp ? 1 : 0.6,
      child: _LuxCard(
        width: width,
        height: 48 * s,
        radius: 16 * s,
        padding: EdgeInsets.symmetric(horizontal: 8 * s),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            HugeIcon(icon: icon, size: 17 * s, color: _muted, strokeWidth: 1.2),
            SizedBox(width: 7 * s),
            Flexible(
              child: Text(
                _shortName(sw.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _muted,
                  fontSize: 11 * s,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The TV as a slim strip (the user needs it least): its name and state,
  /// volume −, play / pause as a gold ring (on the Hisense with a box
  /// behind it, MEDIA_BOX — else the TV's own OK), volume +, power. A box
  /// (Beyond, Haam's TCL) gets its own power; volume goes to the Hisense
  /// when there is one, else to the box over ADB.
  Widget _tvCard(HisenseTv? tv, AndroidTvBox? box) {
    final s = _s;
    final gold = _goldFor(widget.night);
    final tvOn = tv != null && _tvOn[tv] == true;
    final tvKnown = tv != null && _tvOn.containsKey(tv);
    final boxOn = box != null && _boxOn[box] == true;
    final boxKnown = box != null && _boxOn.containsKey(box);
    final boxProblem = box == null
        ? null
        : box.waiting
        ? 'Allow on TV'
        : _boxProblem[box];
    final volumeLive = tv != null ? tvOn : boxOn;

    String state(bool known, bool on, String? detail) => !known
        ? 'CONNECTING'
        : on
        ? (detail ?? 'ON').toUpperCase()
        : 'OFF';
    final label = [
      if (box != null)
        '${box.name}  ·  ${boxProblem?.toUpperCase() ?? state(boxKnown, boxOn, null)}',
      if (tv != null) '${tv.name}  ·  ${state(tvKnown, tvOn, _tvSource[tv])}',
    ].join('   ').toUpperCase();

    Widget volume(IconData icon, String hisenseKey, String adbKey) => _luxIcon(
      icon,
      14 * s,
      volumeLive
          ? _ivory.withValues(alpha: 0.8)
          : _muted.withValues(alpha: 0.5),
      !volumeLive
          ? null
          : tv != null
          ? () => tv.sendKey(hisenseKey).catchError((_) {})
          : () async {
              try {
                await box!.sendKey(await _loadAdbKey(), adbKey);
              } catch (_) {}
            },
      box: 40 * s,
    );

    return _LuxCard(
      height: 48 * s,
      radius: 24 * s,
      lit: tvOn || boxOn ? gold : null,
      padding: EdgeInsets.only(left: 18 * s, right: 4 * s),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _caps(
                9.5 * s,
                color: boxProblem != null ? _red : _muted,
                spacing: 0.28,
              ),
            ),
          ),
          volume(Icons.remove, 'KEY_VOLUMEDOWN', 'KEYCODE_VOLUME_DOWN'),
          volume(Icons.add, 'KEY_VOLUMEUP', 'KEYCODE_VOLUME_UP'),
          // OK / play-pause, beside power (out of the middle, where it was hard
          // to hit — the user asked, 10 Nov 2026), on the Hisense on its own (M&M's Room) only —
          // the user asked for it there and nowhere else (9 Nov 2026).
          if (tv != null && box == null)
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: !tvOn
                  ? null
                  : _mediaBoxes[tv.name] != null
                  ? () async {
                      try {
                        await _mediaBoxes[tv.name]!.sendKey(
                          await _loadAdbKey(),
                          'KEYCODE_MEDIA_PLAY_PAUSE',
                        );
                      } catch (_) {}
                    }
                  : () => tv.sendKey('KEY_OK').catchError((_) {}),
              child: Container(
                width: 36 * s,
                height: 36 * s,
                margin: EdgeInsets.symmetric(horizontal: 4 * s),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: tvOn ? gold : gold.withValues(alpha: 0.35),
                  ),
                ),
                child: Icon(
                  Icons.play_arrow_outlined,
                  size: 16 * s,
                  color: tvOn ? gold : gold.withValues(alpha: 0.35),
                ),
              ),
            ),
          if (box != null)
            _luxIcon(
              Icons.power_settings_new_rounded,
              16 * s,
              boxOn ? gold : _muted,
              boxKnown ? () => _toggleBox(box) : null,
              box: 40 * s,
            ),
          if (tv != null)
            _luxIcon(
              box != null
                  ? Icons.tv_outlined
                  : Icons.power_settings_new_rounded,
              16 * s,
              tvOn ? gold : _muted,
              tvKnown ? () => _toggleTv(tv) : null,
              box: 40 * s,
            ),
        ],
      ),
    );
  }
}

/// An air conditioner's tile: name and a mode badge top-left, power
/// top-right, the setpoint dial in the middle, − / room temp / + along the
/// foot. Its colour follows the mode — cyan cooling, orange heating.
/// Polls every 15 s while the app is on screen.
class AcPanel extends StatefulWidget {
  const AcPanel({
    super.key,
    required this.ac,
    required this.width,
    required this.unit,
    this.night = false,
    this.nudge,
    this.onOffline,
    this.wide = false,
  });

  final GreeAc ac;

  /// The only AC in its room: one card across the panel — name, mode and
  /// room temperature left, the dial in the middle, power and − / + right.
  final bool wide;

  /// Told whether the unit stopped (or started) answering — for the
  /// panel's status line.
  final ValueChanged<bool>? onOffline;

  /// Re-read the unit now whenever this ticks (a scene just changed it).
  final Listenable? nudge;

  /// The tile's width; it's 1.3× as tall.
  final double width;
  final double unit;
  final bool night;

  @override
  State<AcPanel> createState() => _AcPanelState();
}

class _AcPanelState extends State<AcPanel> with WidgetsBindingObserver {
  AcState? _state;
  bool _offlineFlag = false;
  bool get _offline => _offlineFlag;
  set _offline(bool v) {
    if (v == _offlineFlag) return;
    _offlineFlag = v;
    widget.onOffline?.call(v);
  }

  bool _busy = false;

  /// A setpoint being dialled in, sent once the user stops moving it.
  int? _pending;

  Timer? _poll;
  Timer? _send;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.nudge?.addListener(_refresh);
    _startPolling();
  }

  void _startPolling() {
    _poll?.cancel();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 15), (_) => _refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startPolling();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _poll?.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.nudge?.removeListener(_refresh);
    _poll?.cancel();
    _send?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final state = await widget.ac.state();
      if (mounted) {
        setState(() {
          _state = state;
          _offline = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _offline = true);
    }
  }

  Future<void> _togglePower() async {
    final on = !(_state?.on ?? false);
    setState(() => _busy = true);
    try {
      await widget.ac.setPower(on);
      _state = _state?.copyWith(on: on);
      _offline = false;
    } catch (_) {
      _offline = true;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _refresh();
  }

  /// Moves the dial to [temp] now and tells the unit 0.7 s after the last
  /// change, so a drag or a run of taps is one command.
  void _dial(int temp) {
    final t = temp.clamp(acMinTemp, acMaxTemp);
    if (t == (_pending ?? _state?.setTemp)) return;
    setState(() => _pending = t);
    _send?.cancel();
    _send = Timer(const Duration(milliseconds: 700), () async {
      try {
        await widget.ac.setTemp(t);
        _state = _state?.copyWith(setTemp: t);
        _offline = false;
      } catch (_) {
        _offline = true;
      }
      if (!mounted) return;
      setState(() => _pending = null);
      _refresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Mock-up pixels to this panel's size (see _LightsPanelState._s).
    final s = widget.unit / (411 * 0.034);
    final night = widget.night;
    final gold = _goldFor(night);
    final state = _state;
    final on = state?.on == true;
    final temp = _pending ?? state?.setTemp ?? 24;
    final mode = state?.mode ?? 1;
    final room = state?.roomTemp;
    final roomText = room == null ? '' : '  ·  ROOM $room°';
    final status = _offline
        ? 'OFFLINE'
        : state == null
        ? 'CONNECTING'
        : on
        ? '${(_acModeNames.elementAtOrNull(mode) ?? 'On').toUpperCase()}$roomText'
        : 'OFF$roomText';
    final live = state != null && !_busy;
    final ink = _muted.withValues(alpha: live ? 1 : 0.5);
    // One wide row (the luxury look): the label, the AC's name and state,
    // then − setpoint + and power. The round dial went with it.
    return _LuxCard(
      width: widget.width,
      height: 76 * s,
      radius: 20 * s,
      lit: on && !_offline ? gold : null,
      alert: _offline,
      padding: EdgeInsets.only(left: 18 * s, right: 4 * s),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('AIR CON', style: _caps(9.5 * s, spacing: 0.32)),
                SizedBox(height: 3 * s),
                Text(
                  widget.ac.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: _ivory,
                    fontSize: 14 * s,
                    fontWeight: FontWeight.w400,
                    height: 1.2,
                  ),
                ),
                SizedBox(height: 3 * s),
                Text(
                  status,
                  maxLines: 1,
                  style: _caps(
                    9 * s,
                    color: _offline
                        ? _red
                        : on
                        ? gold
                        : _muted,
                    spacing: 0.25,
                  ),
                ),
              ],
            ),
          ),
          _luxIcon(
            Icons.remove,
            15 * s,
            ink,
            live ? () => _dial(temp - 1) : null,
          ),
          SizedBox(
            width: 62 * s,
            child: Text(
              '$temp°',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: _jost,
                fontWeight: FontWeight.w300,
                fontSize: 34 * s,
                height: 1,
                color: on ? _ivory : _ivory.withValues(alpha: 0.6),
              ),
            ),
          ),
          _luxIcon(Icons.add, 15 * s, ink, live ? () => _dial(temp + 1) : null),
          _luxIcon(
            Icons.power_settings_new_rounded,
            17 * s,
            on ? gold : ink,
            live ? _togglePower : null,
          ),
        ],
      ),
    );
  }
}

/// The holiday line's red, in every mode and in standby (the user asked,
/// 10 Nov 2026).
const _holidayRed = Color(0xFFFF4A3D);
