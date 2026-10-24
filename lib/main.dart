import 'dart:async';
import 'dart:isolate';
import 'dart:io' show InternetAddressType, NetworkInterface;
import 'dart:math';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'adb.dart';
import 'gree.dart';
import 'lights.dart';
import 'tv.dart';
import 'weather.dart';

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

/// The time's tint at night — a soft red over Nabla's own colours.
const _nightTime = Color(0xFFFF8A75);

/// The clock face: Nabla, a colour font — its digits carry their own
/// palette, so the time ignores text colour. Every glyph sits in a fixed slot, measured with a
/// TextPainter as a fraction of the font size, so a narrow "1" doesn't
/// change the clock's width from minute to minute.
const _digitFont = 'Nabla';
const _digitFontNight = 'NablaNight';
const _digitSlot = 0.52;
const _colonSlot = 0.312;

/// How much of the room it's given the face actually fills. This is the size
/// dial, not `digitSize` — that deliberately overshoots and the `FittedBox`
/// scales it back to whatever box it's handed, so shrinking it changes
/// nothing. Edge to edge was too big both ways up; the user asked for 20%
/// less, first standing and then on its side.
const _faceScale = 0.8;

/// Holds [child] to [width], shrinking it if it would be wider. The time is
/// what should set the face width, stacked or across; without this a long
/// date or a wide platform font would, and the digits would shrink to suit.
/// The brightness presets on a dimmable light's tile.
const _presets = [1, 25, 50, 100];

Widget _capWidth(double width, Widget child) {
  return SizedBox(
    width: width,
    child: FittedBox(fit: BoxFit.scaleDown, child: child),
  );
}

class _ClockScreenState extends State<ClockScreen> with WidgetsBindingObserver {
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
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
  );

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

  /// Any touch restarts the walk back to this device's own room.
  void _touched() {
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
  final _random = Random();
  Timer? _tick;
  Timer? _driftTimer;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable().catchError((_) {});
    // The brightness override needs an attached activity, which isn't there
    // yet during initState — wait for the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyBrightness(force: true);
    });
    _loadSettings();
    _startTimers();

    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) setState(() => _showHint = false);
    });
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

  void _startTimers() {
    _scheduleTick();
    _refreshWeather();
    _weatherTimer?.cancel();
    _weatherTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => _refreshWeather(),
    );
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
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Not visible — stop burning CPU on clock updates.
      _stopTimers();
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
    });
    _applyBrightness();
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
  Widget _weatherCard(Weather w, double d, bool night) {
    final daylight = _now.hour >= 6 && _now.hour < 18;
    final size = d * 0.46;
    final Widget icon;
    if (w.raining) {
      // A cloud with three drops under it.
      icon = SizedBox.square(
        dimension: size,
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: Icon(
                Icons.cloud_rounded,
                size: size * 0.82,
                color: _white.withValues(alpha: 0.92),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < 3; i++)
                    Icon(
                      Icons.water_drop_rounded,
                      size: size * 0.24,
                      color: _hue(const Color(0xFF7CC4FF), night),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    } else if (daylight) {
      icon = Icon(
        Icons.wb_sunny_rounded,
        size: size,
        color: _hue(const Color(0xFFFFC94D), night),
      );
    } else {
      icon = Icon(
        Icons.nightlight_round,
        size: size,
        color: _hue(const Color(0xFFD5DCFF), night),
      );
    }
    // No card behind it. Nabla like the time and date, in the same palette;
    // its own shading keeps it legible over any sky.
    final font = night ? _digitFontNight : _digitFont;
    return SizedBox(
      width: d * 1.3,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          icon,
          SizedBox(height: d * 0.04),
          Text(
            '${w.temp}°C',
            style: TextStyle(
              fontFamily: font,
              fontSize: d * 0.42,
              height: 1.05,
            ),
          ),
        ],
      ),
    );
  }

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
      child = HomePanel(
        key: const ValueKey('home'),
        rooms: _rooms,
        here: _homeRoom,
        width: width,
        unit: unit,
        night: night,
        onOpen: (i) => setState(() {
          if (_rooms[i].pin != null && i != _homeRoom) {
            _asking = i;
          } else {
            _room = i;
          }
        }),
      );
    } else {
      final room = _rooms[index];
      child = LightsPanel(
        key: ValueKey(room.name),
        title: _rooms.length > 1 ? room.name : null,
        subtitle: room.subtitle,
        onHome: _rooms.length > 1 ? () => setState(() => _room = null) : null,
        lights: room.lights,
        acs: room.acs,
        tvs: room.tvs,
        boxes: room.boxes,
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

  @override
  Widget build(BuildContext context) {
    // Always 24-hour: the user dropped the 12h/AM-PM and seconds options.
    final hh = _now.hour.toString().padLeft(2, '0');
    final mm = _now.minute.toString().padLeft(2, '0');
    final night = _isNight(_now);
    final timeColor = night ? _nightTime : _white;

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
              // The stand holds the phone upright on the charger; turned on
              // its side it slides off the coil and stops charging, so both
              // ways up have to read as a clock.
              final landscape = w > h;

              // Burn-in drift, further along the panel's long axis. Small
              // now: the sky behind is always moving, so only the clock and
              // cards need it (it was ±20×±40 on a static black screen).
              final driftX = landscape ? 12.0 : 8.0;
              final driftY = landscape ? 8.0 : 12.0;

              // HH:MM on one line both ways up — standing, that leaves the
              // panel's height for the lights and AC. Overshoots on purpose:
              // the FittedBox below scales the column down until it fills its
              // box, and scaleDown never scales up.
              final digitSize = min(w * 0.55, h * 1.15);
              // The time's own width: four digit slots and the colon's.
              final timeWidth = digitSize * (4 * _digitSlot + _colonSlot);
              // Everything under the time is held to this — otherwise a long
              // date sets the width and the digits shrink to suit. Narrower
              // than the time on purpose: a full-width rule reads as an
              // underline rather than a divider.
              final faceWidth = timeWidth * 0.61;
              final gap = digitSize * 0.07;
              // The panel sizes off the screen's short side, so it's the same
              // size whichever way up the phone is.
              final barSpan = min(w, h);
              final digitStyle = TextStyle(
                // Palette 0 by day, palette 3 at night — the user's picks.
                fontFamily: night ? _digitFontNight : _digitFont,
                fontSize: digitSize,
                height: 1.0,
              );
              // The date in Nabla too, same palette as the time — Inter looked
              // flat beside the 3D digits.
              final dateStyle = TextStyle(
                fontFamily: night ? _digitFontNight : _digitFont,
                fontSize: digitSize * 0.2,
                height: 1.0,
                letterSpacing: digitSize * 0.012,
              );

              Widget slot(String ch, double width) => SizedBox(
                width: digitSize * width,
                child: Center(child: Text(ch, style: digitStyle)),
              );
              final digits = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  slot(hh[0], _digitSlot),
                  slot(hh[1], _digitSlot),
                  slot(':', _colonSlot),
                  slot(mm[0], _digitSlot),
                  slot(mm[1], _digitSlot),
                ],
              );
              final time = digits;

              final weather = _weather;

              final face = Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  time,
                  SizedBox(height: gap),
                  Container(
                    width: faceWidth,
                    height: max(1.5, digitSize * 0.0045),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(2),
                      gradient: LinearGradient(
                        colors: [
                          timeColor.withValues(alpha: 0),
                          timeColor.withValues(alpha: 0.55),
                          timeColor.withValues(alpha: 0),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(height: gap),
                  _capWidth(
                    timeWidth * 0.85,
                    Text(
                      '${_weekdays[_now.weekday - 1]}  ·  '
                              '${_months[_now.month - 1]} ${_now.day}'
                          .toUpperCase(),
                      style: dateStyle,
                    ),
                  ),
                ],
              );
              // Clock on the left, the weather card on the right (the user's
              // reference: a wall panel with a frosted weather tile). On its
              // side the clock column is narrow, so the card goes under it.
              final card = weather == null
                  ? null
                  : _weatherCard(weather, digitSize, night);
              final faceAndWeather = card == null
                  ? face
                  : landscape
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        face,
                        SizedBox(height: gap * 2),
                        card,
                      ],
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        face,
                        SizedBox(width: digitSize * 0.2),
                        card,
                      ],
                    );

              return Opacity(
                opacity: _pixelOpacity,
                child: Stack(
                  children: [
                    // Soft and edgeless, so it doesn't drift with the rest.
                    Positioned.fill(
                      child: _Backdrop(
                        now: _now,
                        night: night,
                        raining:
                            (_weather?.raining == true &&
                                !const bool.fromEnvironment('FORCE_CLEAR')) ||
                            const bool.fromEnvironment('FORCE_RAIN'),
                        drift: Offset(_drift.dx * driftX, _drift.dy * driftY),
                        home: _room == null && _rooms.length > 1,
                      ),
                    ),
                    // A plain jump, once a minute: a 20 s glide redrew the whole
                    // screen at 60 fps for a third of every minute.
                    Transform.translate(
                      offset: Offset(_drift.dx * driftX, _drift.dy * driftY),
                      child: Stack(
                        children: [
                          // Inset by the drift range so the face never wanders
                          // off the panel edge.
                          Positioned.fill(
                            child: Padding(
                              padding: EdgeInsets.fromLTRB(
                                driftX + 4,
                                driftY + 4,
                                driftX + 4,
                                driftY + 4,
                              ),
                              // The dashboard: the clock takes what the lights
                              // leave — under it standing, beside it on its side.
                              child: Flex(
                                direction: landscape
                                    ? Axis.horizontal
                                    : Axis.vertical,
                                children: [
                                  Expanded(
                                    child: FractionallySizedBox(
                                      // Standing, 0.82: wider runs the top-right
                                      // digit into a dark patch on this OLED.
                                      widthFactor: landscape
                                          ? _faceScale
                                          : 0.82,
                                      heightFactor: landscape ? _faceScale : 1,
                                      // scaleDown fits the stack to that box: the time
                                      // is what binds, so this fills it without ever
                                      // wrapping or clipping.
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        child: faceAndWeather,
                                      ),
                                    ),
                                  ),
                                  if (_rooms.length > 1 ||
                                      !_rooms.first.isEmpty)
                                    Padding(
                                      padding: landscape
                                          ? EdgeInsets.only(
                                              left: barSpan * 0.04,
                                            )
                                          : EdgeInsets.only(
                                              top: barSpan * 0.04,
                                            ),
                                      // Scrolls once there's more than fits. On
                                      // its side the row bounds its height;
                                      // standing, it leaves the clock at least
                                      // 0.4 of the width in height (full width
                                      // needs ~0.45, so it gives a little before
                                      // the panel has to scroll).
                                      child: ConstrainedBox(
                                        constraints: BoxConstraints(
                                          maxHeight: landscape
                                              ? double.infinity
                                              : max(
                                                  0.0,
                                                  h -
                                                      2 * (driftY + 4) -
                                                      barSpan * 0.04 -
                                                      (w - 2 * (driftX + 4)) *
                                                          0.4,
                                                ),
                                        ),
                                        child: SingleChildScrollView(
                                          child: _panel(
                                            night: night,
                                            width: landscape
                                                ? barSpan * 0.034 * 26
                                                : w - 2 * (driftX + 4),
                                            unit: barSpan * 0.034,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (_dimFrom != null)
                            Positioned(
                              left: 0,
                              right: 0,
                              top: barSpan * 0.08,
                              child: Center(
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: 0.6),
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: _surfaceEdge),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(
                                        Icons.brightness_6_rounded,
                                        size: 18,
                                        color: _white,
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '${(_dim * 100).round()}%',
                                        style: const TextStyle(
                                          color: _white,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
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
                              // Landscape leaves no headroom over the digits, so
                              // the hint sits right at the edge and on one line.
                              top: landscape ? 4.0 : barSpan * 0.08,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Text(
                                    'press & hold, then slide up / down to dim',
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.35,
                                      ),
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
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
const _cool = Color(0xFFBFE0FF);
const _tvViolet = Color(0xFFB69CFF);

/// The set-top box's button — a sky blue beside the TV's violet.
const _boxBlue = Color(0xFF5EC8FF);
const _acCool = Color(0xFF4FD8EB);
const _acHeat = Color(0xFFFF8A4C);

/// The setpoint dial, 16° to 30°: cyan, mint, yellow, orange. Straight
/// cyan-to-orange goes through grey in the middle.
const _dialStops = [_acCool, Color(0xFF6EE7A0), Color(0xFFFFD166), _acHeat];

/// AC mode colours, by Gree's mode number: auto, cool, dry, fan, heat.
const _acModeHues = [
  Color(0xFF5EEAD4),
  _acCool,
  Color(0xFF7CB8FF),
  Color(0xFF6EE7A0),
  _acHeat,
];
const _acModeNames = ['Auto', 'Cool', 'Dry', 'Fan', 'Heat'];
const _acModeIcons = [
  Icons.autorenew_rounded,
  Icons.ac_unit_rounded,
  Icons.water_drop_rounded,
  Icons.air_rounded,
  Icons.local_fire_department_rounded,
];

/// Night mode: every hue is pulled most of the way to this deep red.
const _nightRed = Color(0xFFFF4A3D);

/// [c], or its night version: mostly red, a trace of its own hue left so
/// the devices still differ.
Color _hue(Color c, bool night) => night ? Color.lerp(c, _nightRed, 0.8)! : c;

/// Neutral surfaces for buttons that aren't a device's own colour.
final _surface = _white.withValues(alpha: 0.06);
final _surfaceEdge = _white.withValues(alpha: 0.10);

/// A light's colour, read off its name: icy white for a "white" or "cool"
/// light, warm amber for anything else.
Color _glowFor(Light light) {
  final name = light.name.toLowerCase();
  return name.contains('white') || name.contains('cool') ? _cool : _warm;
}

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

/// The sky behind everything, by time of day and weather — a static
/// gradient and glows, with an animated [_Sky] over them:
/// - after dark (19:00–06:00): near-black, drifting twinkling stars densest
///   behind the clock, the odd shooting star, slow nebula glows;
/// - morning (06:00–11:00): a sunrise wash, the sun rising beside the clock
///   with slowly turning rays, drifting clouds, floating motes;
/// - day (11:00–17:00): deep blue, the sun high and small, clouds, motes;
/// - evening (17:00–19:00): violet into a sunset glow, pink clouds, motes;
/// - raining: slate, dark clouds rolling, three layers of rain, splashes,
///   now and then a lightning flash (faint at night).
/// Everything with an edge keeps moving, so nothing burns into the OLED.
class _Backdrop extends StatelessWidget {
  const _Backdrop({
    required this.now,
    required this.night,
    required this.raining,
    required this.drift,
    this.home = false,
  });
  final DateTime now;
  final bool night;
  final bool raining;
  final Offset drift;

  /// The home page is open: it has its own clip (the forest), whatever
  /// the time or weather.
  final bool home;

  @override
  Widget build(BuildContext context) {
    final dark = night || _isDark(now);
    final _Scene scene;
    final List<Color> sky;
    final List<Widget> glows;
    if (dark) {
      scene = raining ? _Scene.nightRain : _Scene.night;
      sky = const [Color(0xFF060818), Color(0xFF020308), Colors.black];
      glows = [];
    } else if (raining) {
      scene = _Scene.rain;
      sky = const [Color(0xFF1C2636), Color(0xFF101722), Color(0xFF0B1A22)];
      glows = [
        _glow(const Alignment(-0.8, -1), 1.4, const Color(0x664F7BA8)),
        _glow(const Alignment(1.2, 0.6), 1.2, const Color(0x332A9D8F)),
      ];
    } else if (_isMorning(now)) {
      scene = _Scene.morning;
      sky = const [Color(0xFF3E1F48), Color(0xFF1D1638), Color(0xFF0B1C2E)];
      glows = [
        _glow(const Alignment(1.2, 0.15), 1.2, const Color(0x4D00B8A9)),
        _glow(const Alignment(-0.6, 1.15), 1.3, const Color(0x47E0457B)),
      ];
    } else if (_isEvening(now)) {
      scene = _Scene.evening;
      sky = const [Color(0xFF241044), Color(0xFF1A0E2E), Color(0xFF3A1426)];
      glows = [
        _glow(const Alignment(-1.1, -0.8), 1.2, const Color(0x596A3DFF)),
        _glow(const Alignment(0.6, 1.25), 1.5, const Color(0x73FF7A45)),
        _glow(const Alignment(-0.8, 1.1), 1.2, const Color(0x59E0457B)),
      ];
    } else {
      scene = _Scene.day;
      sky = const [Color(0xFF0B3A73), Color(0xFF0B2350), Color(0xFF06283A)];
      glows = [
        _glow(const Alignment(1.2, 0.2), 1.2, const Color(0x4D22D3EE)),
        _glow(const Alignment(-0.7, 1.15), 1.3, const Color(0x408B5CF6)),
      ];
    }
    // Which of the user's clips: rainy whenever it rains, else sunny by
    // day (mornings too — the user dropped the morning clip) and night
    // after dark. The user wants a video at all times; rain after dark
    // gets a much darker wash instead.
    // The home page has its own clip, at any hour.
    final clip = home
        ? 'homescreen'
        : raining
        ? 'rainy'
        : dark
        ? 'night'
        : 'sunny';
    final drawnSky = _Sky(
      scene: scene,
      // 06:00 low on the left, 11:00 higher and further in.
      sunRise: ((now.hour + now.minute / 60 - 6) / 5).clamp(0, 1),
      // Night mode: everything bright in the sky goes softer.
      dim: night,
      drift: drift,
    );
    return AnimatedSwitcher(
      duration: const Duration(seconds: 3),
      child: Stack(
        key: ValueKey('$scene/$clip'),
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: sky,
                ),
              ),
            ),
          ),
          ...glows,
          Positioned.fill(
            child: const bool.fromEnvironment('NO_VIDEO')
                ? drawnSky
                // The user's own clips play behind everything, falling
                // back to the drawn sky if one can't load.
                : _VideoSky(
                    asset: 'assets/video/$clip.mp4',
                    fallback: drawnSky,
                    dim: night || (dark && (raining || home)),
                    veryDark: dark && raining,
                  ),
          ),
        ],
      ),
    );
  }

  static Widget _glow(Alignment at, double size, Color color) => Align(
    alignment: at,
    child: FractionallySizedBox(
      widthFactor: size,
      heightFactor: size,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    ),
  );
}

enum _Scene { night, nightRain, rain, morning, day, evening }

/// A looping, silent background video — the user's sunny / rainy clips,
/// shrunk to 1280×720 at 15 fps (hardware-decoded; far cheaper than
/// drawing). A dark wash over it keeps the clock and cards legible. Shows
/// [fallback] until the video is ready, or for good if it can't load (the
/// clips are gitignored, so a fresh clone has none). Pauses whenever the
/// app is off screen, and mixes with other audio so it never pauses music.
class _VideoSky extends StatefulWidget {
  const _VideoSky({
    required this.asset,
    required this.fallback,
    this.dim = false,
    this.veryDark = false,
  });
  final String asset;
  final Widget fallback;

  /// Night mode: a heavier dark wash.
  final bool dim;

  /// The bright rainy clip after dark: darker still.
  final bool veryDark;

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
    return Stack(
      fit: StackFit.expand,
      children: [
        FittedBox(
          fit: BoxFit.cover,
          clipBehavior: Clip.hardEdge,
          child: SizedBox(
            width: video.value.size.width,
            height: video.value.size.height,
            child: VideoPlayer(video),
          ),
        ),
        // Darker at the top behind the clock and at the foot, lighter in
        // between, so the bright footage doesn't swamp the dashboard.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: widget.veryDark
                  ? const [
                      Color(0xE0000000),
                      Color(0xCC000000),
                      Color(0xE0000000),
                    ]
                  : widget.dim
                  ? const [
                      Color(0xB3000000),
                      Color(0x8C000000),
                      Color(0xB3000000),
                    ]
                  : const [
                      Color(0x99000000),
                      Color(0x59000000),
                      Color(0x80000000),
                    ],
              stops: const [0, 0.45, 1],
            ),
          ),
        ),
      ],
    );
  }
}

/// The animated layer: one painter, redrawn ~30 times a second off a
/// ticker (which Flutter pauses whenever the app isn't on screen). It
/// repaints in its own layer without rebuilding any widgets.
class _Sky extends StatefulWidget {
  const _Sky({
    required this.scene,
    required this.sunRise,
    required this.dim,
    required this.drift,
  });
  final _Scene scene;
  final double sunRise;
  final bool dim;
  final Offset drift;

  @override
  State<_Sky> createState() => _SkyState();
}

class _SkyState extends State<_Sky> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _time = ValueNotifier<double>(0);
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    // FREEZE_SKY=true (dart-define) draws one frame and stops — for
    // measuring what the animation costs.
    if (const bool.fromEnvironment('FREEZE_SKY')) {
      _ticker = createTicker((_) {});
      return;
    }
    _ticker = createTicker((elapsed) {
      // One frame every 2 s. Smooth motion (20 fps) cost ~200–400 mA
      // measured on the phone — more than slow wireless charging could
      // cover, so the battery stalled; every 2 s is within noise of a
      // frozen sky. Stars still twinkle, clouds and rain move in calm
      // steps. SKY_FRAME_MS overrides it for testing.
      if (elapsed - _last <
          const Duration(
            milliseconds: int.fromEnvironment(
              'SKY_FRAME_MS',
              defaultValue: 2000,
            ),
          )) {
        return;
      }
      _last = elapsed;
      _time.value = elapsed.inMicroseconds / 1e6;
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: Size.infinite,
      painter: _SkyPainter(
        scene: widget.scene,
        sunRise: widget.sunRise,
        dim: widget.dim,
        drift: widget.drift,
        time: _time,
      ),
    ),
  );
}

class _SkyPainter extends CustomPainter {
  _SkyPainter({
    required this.scene,
    required this.sunRise,
    required this.dim,
    required this.drift,
    required this.time,
  }) : super(repaint: time);

  final _Scene scene;
  final double sunRise;
  final bool dim;
  final Offset drift;
  final ValueNotifier<double> time;

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    switch (scene) {
      case _Scene.night:
        _nebula(canvas, size, t);
        _stars(canvas, size, t);
        _shootingStar(canvas, size, t);
      case _Scene.nightRain:
        _clouds(canvas, size, t, const Color(0xFF4A5568), 0.45, top: true);
        _rain(canvas, size, t, 0.45);
        _lightning(canvas, size, t, dim ? 0.03 : 0.06);
      case _Scene.rain:
        _clouds(canvas, size, t, const Color(0xFF6E7D94), 0.6, top: true);
        _rain(canvas, size, t, 1);
        _lightning(canvas, size, t, 0.14);
      case _Scene.morning:
        _sun(canvas, size, t, sunRise, 1);
        _clouds(canvas, size, t, const Color(0xFFFFE3D3), 0.38);
        _motes(canvas, size, t, const Color(0xFFFFE2B8));
      case _Scene.day:
        _sun(canvas, size, t, 1, 0.75);
        _clouds(canvas, size, t, const Color(0xFFF2F7FF), 0.4);
        _motes(canvas, size, t, const Color(0xFFDDF4FF));
      case _Scene.evening:
        _clouds(canvas, size, t, const Color(0xFFFFB0C0), 0.38);
        _motes(canvas, size, t, const Color(0xFFFFC2A8));
    }
  }

  /// Stars that twinkle and pan slowly left, wrapping round; two in three
  /// sit in the top third, around the clock. The bright ones get a halo
  /// and a four-point glint.
  void _stars(Canvas canvas, Size size, double t) {
    final rng = Random(7);
    final paint = Paint();
    final glint = Paint()
      ..strokeWidth = 0.8
      ..strokeCap = StrokeCap.round;
    final pan = t * 3;
    for (var i = 0; i < 170; i++) {
      final top = i % 3 != 0;
      final x = (rng.nextDouble() * size.width - pan) % size.width;
      final y = rng.nextDouble() * size.height * (top ? 0.36 : 1);
      final p = Offset(x, y) + drift;
      final big = rng.nextDouble() < 0.12;
      final r = big ? 1.5 + rng.nextDouble() : 0.6 + rng.nextDouble() * 0.8;
      final base = big ? 0.8 : 0.25 + rng.nextDouble() * 0.4;
      final speed = 0.6 + rng.nextDouble() * 1.4;
      final a = base * (0.5 + 0.5 * sin(t * speed + i * 1.7));
      paint.color = const Color(0xFFFFF4E6).withValues(alpha: a);
      canvas.drawCircle(p, r, paint);
      if (big) {
        paint.color = const Color(0xFFFFF4E6).withValues(alpha: a * 0.18);
        canvas.drawCircle(p, r * 3.2, paint);
        glint.color = const Color(0xFFFFF4E6).withValues(alpha: a * 0.5);
        canvas.drawLine(p - Offset(r * 4, 0), p + Offset(r * 4, 0), glint);
        canvas.drawLine(p - Offset(0, r * 4), p + Offset(0, r * 4), glint);
      }
    }
  }

  /// One shooting star every 23 s, across the top, gone in about a second.
  void _shootingStar(Canvas canvas, Size size, double t) {
    const period = 23.0;
    const life = 1.1;
    final n = (t / period).floor();
    final u = (t - n * period) / life;
    if (u > 1) return;
    final rng = Random(n * 31 + 5);
    final start = Offset(
      size.width * (0.25 + rng.nextDouble() * 0.6),
      size.height * rng.nextDouble() * 0.25,
    );
    const dir = Offset(-0.85, 0.5);
    final head = start + dir * (size.width * 0.5 * u);
    final tail = head - dir * (size.width * 0.18);
    final fade = sin(u * pi); // in and out
    canvas.drawLine(
      tail,
      head,
      Paint()
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..shader = LinearGradient(
          colors: [
            const Color(0x00FFFFFF),
            Colors.white.withValues(alpha: 0.85 * fade),
          ],
        ).createShader(Rect.fromPoints(tail, head)),
    );
    canvas.drawCircle(
      head,
      2.2,
      Paint()..color = Colors.white.withValues(alpha: 0.9 * fade),
    );
  }

  /// Two faint violet and teal clouds of light wandering behind the stars.
  void _nebula(Canvas canvas, Size size, double t) {
    final s = max(size.width, size.height);
    void blob(Offset c, double r, Color color) => canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
        ).createShader(Rect.fromCircle(center: c, radius: r)),
    );
    blob(
      Offset(
        size.width * (0.3 + 0.15 * sin(t * 0.021)),
        size.height * (0.25 + 0.08 * cos(t * 0.017)),
      ),
      s * 0.45,
      const Color(0xFF5B3BC4).withValues(alpha: dim ? 0.06 : 0.1),
    );
    blob(
      Offset(
        size.width * (0.75 + 0.12 * cos(t * 0.015)),
        size.height * (0.7 + 0.1 * sin(t * 0.019)),
      ),
      s * 0.4,
      const Color(0xFF0E8C8C).withValues(alpha: dim ? 0.05 : 0.08),
    );
  }

  /// Clouds drifting right. Each is a cluster of puffs — solid in the
  /// middle, feathered at the edge — drawn into its own layer and faded as
  /// one, so overlapping puffs don't stack into blotches. [top] keeps them
  /// in the upper third (rain clouds).
  void _clouds(
    Canvas canvas,
    Size size,
    double t,
    Color color,
    double alpha, {
    bool top = false,
  }) {
    // Puff layout in units of the cloud's width: (dx, dy, radius).
    const puffs = [
      (-0.36, 0.06, 0.19),
      (-0.18, -0.06, 0.25),
      (0.04, -0.14, 0.3),
      (0.26, -0.04, 0.24),
      (0.4, 0.07, 0.17),
      (-0.06, 0.1, 0.26),
      (0.2, 0.11, 0.22),
    ];
    final rng = Random(3);
    final a = alpha * (dim ? 0.5 : 1);
    for (var i = 0; i < 6; i++) {
      final w =
          size.width * (top ? 0.42 : 0.3) * (0.7 + rng.nextDouble() * 0.5);
      final speed = 5 + rng.nextDouble() * 9;
      final span = size.width + w * 1.6;
      final x = (rng.nextDouble() * span + t * speed) % span - w * 0.8;
      final y =
          size.height *
          (top
              ? 0.02 + rng.nextDouble() * 0.2
              : 0.03 + rng.nextDouble() * 0.27);
      final layerAlpha = a * (0.55 + rng.nextDouble() * 0.45);
      final bounds = Rect.fromCenter(
        center: Offset(x, y),
        width: w * 1.6,
        height: w * 0.9,
      );
      canvas.saveLayer(
        bounds,
        Paint()..color = Colors.white.withValues(alpha: layerAlpha),
      );
      for (final (dx, dy, pr) in puffs) {
        final c = Offset(x + dx * w, y + dy * w);
        final r = pr * w;
        canvas.drawCircle(
          c,
          r,
          Paint()
            ..shader = RadialGradient(
              colors: [color, color, color.withValues(alpha: 0)],
              stops: const [0, 0.62, 1],
            ).createShader(Rect.fromCircle(center: c, radius: r)),
        );
      }
      canvas.restore();
    }
  }

  /// Rain in three layers — far drops thin, short and slow, near ones
  /// long, bright and fast — and splashes rippling out low on the screen.
  void _rain(Canvas canvas, Size size, double t, double opacity) {
    final rng = Random(11);
    final paint = Paint()..strokeCap = StrokeCap.round;
    const slant = -0.18;
    for (final (count, speed, length, width, alpha) in const [
      (70, 380.0, 12.0, 0.8, 0.12),
      (55, 620.0, 18.0, 1.1, 0.2),
      (30, 900.0, 28.0, 1.5, 0.3),
    ]) {
      paint.strokeWidth = width;
      for (var i = 0; i < count; i++) {
        final v = speed * (0.85 + rng.nextDouble() * 0.3);
        final span = size.height + length;
        final y = (rng.nextDouble() * span + t * v) % span - length;
        final x = rng.nextDouble() * (size.width + 80) + y * slant;
        paint.color = const Color(
          0xFFBFD9FF,
        ).withValues(alpha: alpha * opacity * (0.7 + rng.nextDouble() * 0.6));
        canvas.drawLine(
          Offset(x, y),
          Offset(x + length * slant, y + length),
          paint,
        );
      }
    }
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (var i = 0; i < 26; i++) {
      final period = 0.7 + rng.nextDouble() * 0.8;
      final phase = rng.nextDouble() * period;
      final u = ((t + phase) % period) / period;
      final c = Offset(
        rng.nextDouble() * size.width,
        size.height * (0.8 + rng.nextDouble() * 0.2),
      );
      ring.color = const Color(
        0xFFBFD9FF,
      ).withValues(alpha: (1 - u) * 0.3 * opacity);
      canvas.drawOval(
        Rect.fromCenter(center: c, width: 4 + u * 22, height: 1.5 + u * 6),
        ring,
      );
    }
  }

  /// A lightning flash every 41 s: two quick pulses lighting the sky.
  void _lightning(Canvas canvas, Size size, double t, double strength) {
    final u = t % 41;
    double pulse(double at) => max(0, 1 - (u - at).abs() / 0.07);
    final f = max(pulse(0.1), pulse(0.32) * 0.7);
    if (f <= 0) return;
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFFDDE8FF).withValues(alpha: f * strength),
    );
  }

  /// The sun up and left of the clock (never top-right — dead OLED patch):
  /// a breathing haze, slowly turning rays, a corona and a warm disc.
  void _sun(Canvas canvas, Size size, double t, double rise, double scale) {
    final short = min(size.width, size.height) * scale;
    final landscape = size.width > size.height;
    final c = Offset(
      size.width * (landscape ? 0.08 + 0.1 * rise : 0.1 + 0.08 * rise),
      size.height * (landscape ? 0.35 - 0.2 * rise : 0.09 - 0.04 * rise),
    );
    final breathe = 1 + 0.05 * sin(t * 0.7);
    void disc(double r, List<Color> colors, [List<double>? stops]) {
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: colors,
            stops: stops,
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }

    disc(short * 0.9 * breathe, const [
      Color(0x47FF9E5E),
      Color(0x14FF6F61),
      Color(0x00FF6F61),
    ]);
    // Rays: long thin wedges, turning a full circle every ~3 minutes.
    final rays = Paint()
      ..shader = RadialGradient(
        colors: const [Color(0x24FFD48A), Color(0x00FFD48A)],
      ).createShader(Rect.fromCircle(center: c, radius: short * 0.5));
    for (var i = 0; i < 12; i++) {
      final a = t * 0.035 + i * pi / 6;
      // Short, so none reaches the dead top-right patch.
      final len = short * (i.isEven ? 0.5 : 0.36);
      final path = Path()
        ..moveTo(c.dx, c.dy)
        ..lineTo(c.dx + cos(a - 0.05) * len, c.dy + sin(a - 0.05) * len)
        ..lineTo(c.dx + cos(a + 0.05) * len, c.dy + sin(a + 0.05) * len)
        ..close();
      canvas.drawPath(path, rays);
    }
    disc(short * 0.28 * breathe, const [Color(0x73FFD48A), Color(0x00FFB86B)]);
    disc(
      short * 0.085,
      const [Color(0xFFFFF1C9), Color(0xFFFFC56B), Color(0x00FFB04A)],
      const [0, 0.75, 1],
    );
  }

  /// Soft motes of light drifting slowly upward, swaying as they go.
  void _motes(Canvas canvas, Size size, double t, Color color) {
    final rng = Random(19);
    for (var i = 0; i < 24; i++) {
      final speed = 6 + rng.nextDouble() * 12;
      final span = size.height + 40;
      final y = size.height + 20 - (rng.nextDouble() * span + t * speed) % span;
      final x =
          rng.nextDouble() * size.width +
          sin(t * (0.3 + rng.nextDouble() * 0.4) + i) * 14;
      final r = 2 + rng.nextDouble() * 5;
      final a = (0.06 + rng.nextDouble() * 0.12) * (dim ? 0.5 : 1);
      final c = Offset(x, y);
      canvas.drawCircle(
        c,
        r,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: a),
              color.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: c, radius: r)),
      );
    }
  }

  @override
  bool shouldRepaint(_SkyPainter old) =>
      old.scene != scene ||
      old.sunRise != sunRise ||
      old.dim != dim ||
      old.drift != drift;
}

/// A frosted-glass card in its device's [hue]: the backdrop blurred through
/// it, a wash of the hue, a thin border that's brightest top-left and fades
/// out, and a glow around it while [on]. [alert] turns the border red.
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
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: on
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
            padding: EdgeInsets.all(unit * 1.1),
            decoration: BoxDecoration(
              gradient: LinearGradient(
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

  bool get isEmpty =>
      lights.isEmpty && acs.isEmpty && tvs.isEmpty && boxes.isEmpty;

  /// "2 lights · 2 ACs · 1 TV", or "No devices yet".
  String get summary {
    String n(int count, String one) => '$count $one${count == 1 ? '' : 's'}';
    final parts = [
      if (lights.isNotEmpty) n(lights.length, 'light'),
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
  List<AndroidTvBox> boxes,
) {
  const spec = String.fromEnvironment('ROOMS');
  if (spec.trim().isEmpty) return [Room('Room', null, lights, acs, tvs, boxes)];
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
      ),
    );
  }
  return rooms.isEmpty ? [Room('Room', null, lights, acs, tvs, boxes)] : rooms;
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
    this.night = false,
  });

  final List<Room> rooms;

  /// The room this device sits in, marked "Here".
  final int here;
  final double width;
  final double unit;
  final bool night;
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
    final tile = (width - gap) / 2;
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
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final (i, room) in rooms.indexed)
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
                                iconFor(room.name),
                                size: u * 1.5,
                                color: room.isEmpty
                                    ? _white.withValues(alpha: 0.4)
                                    : amber,
                              ),
                            ),
                            const Spacer(),
                            if (room.pin != null && i != here)
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
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const Spacer(),
                        Text(
                          room.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _white,
                            fontSize: u * 1.0,
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        Text(
                          room.subtitle ?? room.summary,
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
          ),
          SizedBox(height: gap),
          _HomeStatus(unit: u, night: night),
        ],
      ),
    );
  }
}

/// The panel's foot (from the user's mock-up): Wi-Fi on the left — green
/// "Connected · Home Wi-Fi", or red "No devices answering" — and on the
/// right "All systems nominal", "Checking devices…" or what's offline.
class _StatusBar extends StatelessWidget {
  const _StatusBar({
    required this.unit,
    required this.night,
    required this.connected,
    this.checking = false,
    this.down = const [],
    this.offlineLabel = 'No devices answering',
  });

  final double unit;
  final bool night;
  final bool connected;
  final bool checking;
  final List<String> down;
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
                    fontWeight: FontWeight.w600,
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
    this.trailing = const [],
  });

  final double unit;
  final bool night;
  final String title;
  final String? subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  final List<Widget> trailing;

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
                  fontWeight: FontWeight.w600,
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
    if (switched != null &&
        DateTime.now().difference(switched) < const Duration(seconds: 6)) {
      return;
    }
    try {
      final on = await box.isOn(await _loadAdbKey());
      if (mounted) {
        setState(() {
          _boxOn[box] = on;
          _boxProblem.remove(box);
        });
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
        setState(() {
          _boxOn[box] = false;
          _boxProblem[box] = 'Use the remote to turn on';
        });
        Future.delayed(const Duration(seconds: 4), () {
          if (mounted && _boxProblem[box] == 'Use the remote to turn on') {
            setState(() => _boxProblem.remove(box));
          }
        });
        return;
      }
      _refreshBox(box);
    }
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
      _states[light] = expected;
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

  @override
  Widget build(BuildContext context) {
    final u = widget.unit;
    final gap = u * 0.8;
    // Square tiles, two to a row.
    final tile = (widget.width - gap) / 2;
    return SizedBox(
      width: widget.width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PanelHeader(
            unit: u,
            night: widget.night,
            title: widget.title ?? 'ROOM DASHBOARD',
            subtitle: widget.title == null ? null : widget.subtitle,
            icon: Icons.home_rounded,
            onTap: widget.onHome,
            trailing: [
              // Scenes (good night, good morning) — only in the room
              // that has their devices.
              if (_hasScenes) ...[
                _pill(
                  Icons.bedtime_rounded,
                  'GN',
                  night: true,
                  enabled: _scene == null,
                  onTap: () => _runScene(true),
                ),
                SizedBox(width: u * 0.5),
                _pill(
                  Icons.wb_sunny_rounded,
                  'GM',
                  night: false,
                  enabled: _scene == null,
                  onTap: () => _runScene(false),
                ),
              ],
            ],
          ),
          if (widget.lights.isEmpty &&
              widget.acs.isEmpty &&
              widget.tvs.isEmpty &&
              widget.boxes.isEmpty) ...[
            SizedBox(height: gap),
            _GlowCard(
              hue: _hue(_warm, widget.night),
              on: false,
              unit: u,
              width: widget.width,
              child: Text(
                'Nothing to control here yet',
                style: TextStyle(
                  color: _white.withValues(alpha: 0.5),
                  fontSize: u * 0.8,
                ),
              ),
            ),
          ],
          SizedBox(height: gap),
          Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [for (final light in widget.lights) _tile(light, tile)],
          ),
          if (widget.acs.isNotEmpty) ...[
            SizedBox(height: gap),
            Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (final ac in widget.acs)
                  AcPanel(
                    ac: ac,
                    width: tile,
                    unit: u,
                    night: widget.night,
                    nudge: _acNudge,
                    onOffline: (off) => setState(
                      () => off ? _acOffline.add(ac) : _acOffline.remove(ac),
                    ),
                  ),
              ],
            ),
          ],
          if (widget.tvs.isNotEmpty || widget.boxes.isNotEmpty) ...[
            SizedBox(height: gap),
            _tvCard(widget.tvs.firstOrNull, widget.boxes.firstOrNull),
          ],
          if (widget.lights.isNotEmpty ||
              widget.acs.isNotEmpty ||
              widget.tvs.isNotEmpty ||
              widget.boxes.isNotEmpty) ...[
            SizedBox(height: gap),
            _statusLine(),
          ],
        ],
      ),
    );
  }

  /// A square tile: one big power button carrying the bulb icon, the name
  /// and its state ("Warm Glow · 50%"), and for a dimmable light a
  /// segmented 1 / 25 / 50 / 100% bar under it. The look follows a mock-up
  /// the user sent (Oct 2026), stacked to fit a narrow tile.
  Widget _tile(Light light, double size) {
    final u = widget.unit;
    final hue = _hue(_glowFor(light), widget.night);
    final state = _states[light];
    final on = state?.on == true;
    final level = state?.brightness;
    final offline = _offline.contains(light);
    final busy = _busy.contains(light);
    final tone = _glowFor(light) == _cool ? 'Icy White' : 'Warm Glow';
    final status = offline
        ? 'Offline'
        : state == null
        ? 'Connecting…'
        : on
        ? (light.dimmable && level != null ? '$tone · $level%' : '$tone · On')
        : 'Off · $tone';
    // On, the button is the light's colour and everything on it is dark.
    final ink = on ? Colors.black.withValues(alpha: 0.85) : _white;
    final r = BorderRadius.circular(u * 1.25);

    Widget chip(double side, double radius, Widget child) => Container(
      width: side,
      height: side,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: on
            ? Colors.black.withValues(alpha: 0.12)
            : _white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(radius),
      ),
      child: child,
    );

    final power = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: busy
          ? null
          : () =>
                _run(light, () => light.setPower(!on), LightState(!on, level)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 350),
        padding: EdgeInsets.all(u * 0.85),
        decoration: BoxDecoration(
          borderRadius: r,
          gradient: on
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    hue,
                    Color.lerp(hue, const Color(0xFFFF6A1A), 0.35)!,
                  ],
                )
              : null,
          color: on ? null : _white.withValues(alpha: 0.05),
          border: Border.all(
            color: offline
                ? _red.withValues(alpha: 0.4)
                : on
                ? _white.withValues(alpha: 0.25)
                : _surfaceEdge,
          ),
          boxShadow: on
              ? [
                  BoxShadow(
                    color: hue.withValues(alpha: 0.35),
                    blurRadius: u * 1.2,
                  ),
                ]
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                chip(
                  u * 2.6,
                  u * 0.8,
                  Icon(
                    offline
                        ? Icons.wifi_off_rounded
                        : on
                        ? Icons.lightbulb_rounded
                        : Icons.lightbulb_outline_rounded,
                    size: u * 1.5,
                    color: offline
                        ? _red
                        : on
                        ? ink
                        : hue.withValues(alpha: 0.75),
                  ),
                ),
                chip(
                  u * 2.2,
                  u * 1.1,
                  busy
                      ? SizedBox.square(
                          dimension: u * 1.1,
                          child: CircularProgressIndicator(
                            strokeWidth: u * 0.15,
                            color: ink,
                          ),
                        )
                      : Icon(
                          Icons.power_settings_new_rounded,
                          size: u * 1.2,
                          color: ink.withValues(alpha: on ? 0.85 : 0.55),
                        ),
                ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  light.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: ink,
                    fontSize: u * 1.0,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
                Text(
                  status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: offline
                        ? _red
                        : on
                        ? ink.withValues(alpha: 0.75)
                        : _white.withValues(alpha: 0.5),
                    fontSize: u * 0.72,
                    fontWeight: FontWeight.w500,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );

    return _GlowCard(
      hue: hue,
      on: on,
      unit: u,
      width: size,
      height: size,
      alert: offline,
      child: Column(
        children: [
          Expanded(child: power),
          if (light.dimmable) ...[
            SizedBox(height: u * 0.7),
            _presetBar(light, hue, on: on, level: level, busy: busy),
          ],
        ],
      ),
    );
  }

  /// 1 · 25 · 50 · 100 in one pill, with a highlight that slides to the
  /// preset nearest the bulb's level (set elsewhere, it rarely lands on one).
  Widget _presetBar(
    Light light,
    Color hue, {
    required bool on,
    required int? level,
    required bool busy,
  }) {
    final u = widget.unit;
    final nearest = level == null
        ? null
        : _presets.reduce(
            (a, b) => (a - level).abs() <= (b - level).abs() ? a : b,
          );
    final index = on && nearest != null ? _presets.indexOf(nearest) : null;
    final r = BorderRadius.circular(u * 1.3);
    return Container(
      height: u * 3,
      padding: EdgeInsets.all(u * 0.22),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: r,
        border: Border.all(color: _surfaceEdge),
      ),
      child: Stack(
        children: [
          if (index != null)
            AnimatedAlign(
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOutCubic,
              alignment: Alignment(-1 + 2 * index / (_presets.length - 1), 0),
              child: FractionallySizedBox(
                widthFactor: 1 / _presets.length,
                heightFactor: 1,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: hue,
                    borderRadius: BorderRadius.circular(u * 1.1),
                    boxShadow: [
                      BoxShadow(
                        color: hue.withValues(alpha: 0.4),
                        blurRadius: u * 0.8,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Row(
            children: [
              for (final (i, pct) in _presets.indexed)
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: busy
                        ? null
                        : () => _run(
                            light,
                            () => light.setBrightness(pct),
                            LightState(true, pct),
                          ),
                    child: Center(
                      child: Text(
                        '$pct%',
                        style: TextStyle(
                          color: i == index
                              ? Colors.black
                              : _white.withValues(alpha: busy ? 0.3 : 0.7),
                          fontSize: u * 0.75,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -u * 0.02,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The TV card, laid out as the user asked: the set-top box's big power
  /// button first, then the TV's own (smaller) power button beside the
  /// volume pill. Volume goes to the TV and is live only while it's on.
  Widget _tvCard(HisenseTv? tv, AndroidTvBox? box) {
    final u = widget.unit;
    final hue = _hue(_tvViolet, widget.night);
    final boxHue = _hue(_boxBlue, widget.night);
    final tvOn = tv != null && _tvOn[tv] == true;
    final tvKnown = tv != null && _tvOn.containsKey(tv);
    final boxOn = box != null && _boxOn[box] == true;
    final boxProblem = box == null
        ? null
        : box.waiting
        ? 'Allow on TV'
        : _boxProblem[box];
    final boxKnown = box != null && _boxOn.containsKey(box);
    final r = BorderRadius.circular(u * 1.25);

    // Volume goes to the Hisense when the card has one, else to the
    // Android TV itself over ADB (a TCL on its own, say).
    final volumeLive = tv != null ? tvOn : boxOn;
    Widget volume(IconData icon, String hisenseKey, String adbKey) => Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: !volumeLive
            ? null
            : tv != null
            ? () => tv.sendKey(hisenseKey).catchError((_) {})
            : () async {
                try {
                  await box!.sendKey(await _loadAdbKey(), adbKey);
                } catch (_) {}
              },
        child: Icon(
          icon,
          size: u * 1.8,
          color: _white.withValues(alpha: volumeLive ? 0.85 : 0.25),
        ),
      ),
    );

    /// A power button in [color]: filled while [on], a tinted outline off.
    BoxDecoration button(Color color, bool on) => BoxDecoration(
      borderRadius: r,
      gradient: on
          ? LinearGradient(colors: [color.withValues(alpha: 0.8), color])
          : null,
      color: on ? null : color.withValues(alpha: 0.06),
      border: Border.all(color: color.withValues(alpha: on ? 0.8 : 0.18)),
    );

    final boxFg = boxOn
        ? Colors.black
        : boxHue.withValues(alpha: boxKnown ? 0.65 : 0.3);
    final tvFg = tvOn
        ? Colors.black
        : hue.withValues(alpha: tvKnown ? 0.65 : 0.25);

    /// A wide power button: the power icon, the name and a state line.
    Widget wide({
      required String name,
      required String status,
      required bool problem,
      required Color color,
      required bool on,
      required Color fg,
      required VoidCallback? onTap,
    }) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        height: u * 5,
        padding: EdgeInsets.symmetric(horizontal: u * 1.1),
        decoration: button(color, on),
        child: Row(
          children: [
            Icon(Icons.power_settings_new_rounded, size: u * 2.1, color: fg),
            SizedBox(width: u * 0.8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      name,
                      maxLines: 1,
                      style: TextStyle(
                        color: fg,
                        fontSize: u * 1.05,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    status,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: problem
                          ? _red
                          : on
                          ? Colors.black.withValues(alpha: 0.65)
                          : _white.withValues(alpha: 0.45),
                      fontSize: u * 0.78,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    return _GlowCard(
      hue: boxOn || !tvOn ? boxHue : hue,
      on: tvOn || boxOn,
      unit: u,
      width: widget.width,
      child: Row(
        children: [
          if (box != null) ...[
            Expanded(
              child: wide(
                name: box.name,
                status:
                    boxProblem ??
                    (!boxKnown
                        ? 'Connecting…'
                        : boxOn
                        ? 'On'
                        : 'Off'),
                problem: boxProblem != null,
                color: boxHue,
                on: boxOn,
                fg: boxFg,
                onTap: boxKnown ? () => _toggleBox(box) : null,
              ),
            ),
            SizedBox(width: u * 0.6),
          ],
          // A TV on its own gets the wide button; beside a box, a square.
          if (tv != null && box == null) ...[
            Expanded(
              child: wide(
                name: tv.name,
                status: !tvKnown
                    ? 'Connecting…'
                    : tvOn
                    ? (_tvSource[tv] ?? 'On')
                    : 'Off',
                problem: false,
                color: hue,
                on: tvOn,
                fg: tvFg,
                onTap: tvKnown ? () => _toggleTv(tv) : null,
              ),
            ),
            SizedBox(width: u * 0.6),
          ],
          if (tv != null && box != null) ...[
            // The TV itself: a small square — TV icon over power.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: tvKnown ? () => _toggleTv(tv) : null,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: u * 5,
                height: u * 5,
                decoration: button(hue, tvOn),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.tv_rounded, size: u * 1.7, color: tvFg),
                    Icon(
                      Icons.power_settings_new_rounded,
                      size: u * 1.2,
                      color: tvFg,
                    ),
                  ],
                ),
              ),
            ),
            SizedBox(width: u * 0.6),
          ],
          if (tv != null || box != null)
            Container(
              width: u * 9,
              height: u * 5,
              decoration: BoxDecoration(
                color: _surface,
                borderRadius: r,
                border: Border.all(color: _surfaceEdge),
              ),
              child: Row(
                children: [
                  volume(
                    Icons.remove_rounded,
                    'KEY_VOLUMEDOWN',
                    'KEYCODE_VOLUME_DOWN',
                  ),
                  Icon(
                    Icons.volume_up_rounded,
                    size: u * 1.2,
                    color: (tv != null ? hue : boxHue).withValues(
                      alpha: volumeLive ? 0.8 : 0.25,
                    ),
                  ),
                  volume(
                    Icons.add_rounded,
                    'KEY_VOLUMEUP',
                    'KEYCODE_VOLUME_UP',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// The foot of the panel (from the user's mock-up): the network on the
  /// left — green while the devices answer — and on the right "All systems
  /// nominal", or which devices stopped answering.
  Widget _statusLine() {
    final down = [
      for (final l in widget.lights)
        if (_offline.contains(l)) l.name,
      for (final ac in widget.acs)
        if (_acOffline.contains(ac)) ac.name,
    ];
    final total = widget.lights.length + widget.acs.length;
    return _StatusBar(
      unit: widget.unit,
      night: widget.night,
      connected: !(total > 0 && down.length == total),
      checking: down.isEmpty && widget.lights.any((l) => _states[l] == null),
      down: down,
    );
  }

  /// A scene button: GN deep navy with a lavender moon, GM a glowing
  /// amber-to-orange sunrise (from the user's mock-up).
  Widget _pill(
    IconData icon,
    String label, {
    required bool night,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final u = widget.unit;
    final amber = _hue(_warm, widget.night);
    final fg = night
        ? const Color(0xFFB9B4FF)
        : Colors.black.withValues(alpha: 0.85);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 300),
        opacity: enabled ? 1 : 0.4,
        child: Container(
          height: u * 2.6,
          padding: EdgeInsets.symmetric(horizontal: u * 0.9),
          decoration: BoxDecoration(
            gradient: night
                ? null
                : LinearGradient(
                    colors: [
                      amber,
                      Color.lerp(amber, const Color(0xFFFF6A1A), 0.4)!,
                    ],
                  ),
            color: night ? const Color(0xE60D1030) : null,
            border: Border.all(
              color: night
                  ? const Color(0x664A4A9A)
                  : _white.withValues(alpha: 0.25),
            ),
            borderRadius: BorderRadius.circular(u * 1.3),
            boxShadow: night || widget.night
                ? null
                : [
                    BoxShadow(
                      color: amber.withValues(alpha: 0.35),
                      blurRadius: u * 1.0,
                    ),
                  ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: u * 1.2, color: fg),
              SizedBox(width: u * 0.4),
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: u * 0.8,
                  fontWeight: FontWeight.w700,
                  letterSpacing: u * 0.04,
                ),
              ),
            ],
          ),
        ),
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
  });

  final GreeAc ac;

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

  /// The setpoint when a press-and-hold on the dial started.
  int? _dialFrom;
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
    final u = widget.unit;
    final night = widget.night;
    final width = widget.width;
    final height = width * 1.3;
    final state = _state;
    final on = state?.on == true;
    final temp = _pending ?? state?.setTemp ?? 24;
    final mode = state?.mode ?? 1;
    final hue = _hue(_acModeHues.elementAtOrNull(mode) ?? _acCool, night);
    final room = state?.roomTemp;
    final pad = u * 1.1;
    // The dial takes the middle: what's left of the height between the
    // header (the power circle) and the − / + row, capped by the width.
    final dialSize = min(
      width - 2 * pad,
      (height - 2 * pad - u * 3.2 - u * 2.6 - u * 0.8) / 0.86,
    );

    // The badge: the mode while on, otherwise why there isn't one.
    final (badgeText, badgeIcon, badgeColor) = _offline
        ? ('Offline', Icons.wifi_off_rounded, _red)
        : state == null
        ? ('Connecting…', null, _white.withValues(alpha: 0.5))
        : !on
        ? ('Off', null, _white.withValues(alpha: 0.5))
        : (
            _acModeNames.elementAtOrNull(mode) ?? 'On',
            _acModeIcons.elementAtOrNull(mode),
            hue,
          );

    Widget roundButton(IconData icon, VoidCallback onTap) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: u * 2.6,
        height: u * 2.6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _surface,
          border: Border.all(color: _surfaceEdge),
        ),
        child: Icon(icon, size: u * 1.3, color: _white.withValues(alpha: 0.85)),
      ),
    );

    return _GlowCard(
      hue: hue,
      on: on,
      unit: u,
      width: width,
      height: height,
      alert: _offline,
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.ac.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _white.withValues(alpha: on ? 0.95 : 0.7),
                        fontSize: u * 1.05,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    SizedBox(height: u * 0.3),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: u * 0.5,
                        vertical: u * 0.15,
                      ),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(u),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (badgeIcon != null) ...[
                            Icon(badgeIcon, size: u * 0.8, color: badgeColor),
                            SizedBox(width: u * 0.25),
                          ],
                          Text(
                            badgeText,
                            style: TextStyle(
                              color: badgeColor,
                              fontSize: u * 0.7,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // Power, a circle in the mode's colour while on.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _busy || state == null ? null : _togglePower,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: u * 3.2,
                  height: u * 3.2,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on ? hue : hue.withValues(alpha: 0.06),
                    border: Border.all(
                      color: hue.withValues(alpha: on ? 1 : 0.25),
                    ),
                    boxShadow: on
                        ? [
                            BoxShadow(
                              color: hue.withValues(alpha: 0.45),
                              blurRadius: u,
                            ),
                          ]
                        : null,
                  ),
                  child: _busy
                      ? Padding(
                          padding: EdgeInsets.all(u * 0.9),
                          child: CircularProgressIndicator(
                            strokeWidth: u * 0.15,
                            color: on ? Colors.black : _white,
                          ),
                        )
                      : Icon(
                          Icons.power_settings_new_rounded,
                          size: u * 1.6,
                          color: on ? Colors.black : hue.withValues(alpha: 0.6),
                        ),
                ),
              ),
            ],
          ),
          const Spacer(),
          // The dial: press and hold, then slide up for warmer, down for
          // cooler — a degree per step, with a tick each. (Plain drags and
          // taps used to set it, and fired by accident.)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onLongPressStart: (_) {
              HapticFeedback.selectionClick();
              _dialFrom = temp;
            },
            onLongPressMoveUpdate: (d) {
              final from = _dialFrom;
              if (from == null) return;
              final t = (from - d.offsetFromOrigin.dy / (u * 1.4)).round();
              if (t.clamp(acMinTemp, acMaxTemp) != temp) {
                HapticFeedback.selectionClick();
              }
              _dial(t);
            },
            onLongPressEnd: (_) => _dialFrom = null,
            child: SizedBox(
              width: dialSize,
              height: dialSize * 0.86,
              child: CustomPaint(
                painter: _DialPainter(
                  value: (temp - acMinTemp) / (acMaxTemp - acMinTemp),
                  // Cold to hot along the arc, so its colour is the setting.
                  colors: [
                    for (final c in _dialStops)
                      on ? _hue(c, night) : _white.withValues(alpha: 0.3),
                  ],
                  unit: u * 0.5,
                ),
                // The box is cut off below the arc, so its middle sits above
                // the circle's; pad the top to centre the readout in the ring.
                child: Padding(
                  padding: EdgeInsets.only(top: dialSize * 0.14),
                  child: Center(
                    child: Text(
                      '$temp°',
                      style: TextStyle(
                        color: _white.withValues(alpha: on ? 1 : 0.5),
                        fontSize: u * 2.4,
                        fontWeight: FontWeight.w300,
                        letterSpacing: -u * 0.05,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          Row(
            children: [
              roundButton(Icons.remove_rounded, () => _dial(temp - 1)),
              Expanded(
                child: room == null
                    ? const SizedBox()
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.thermostat_rounded,
                            size: u * 0.9,
                            color: _white.withValues(alpha: 0.5),
                          ),
                          Text(
                            '$room°',
                            style: TextStyle(
                              color: _white.withValues(alpha: 0.6),
                              fontSize: u * 0.8,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
              ),
              roundButton(Icons.add_rounded, () => _dial(temp + 1)),
            ],
          ),
        ],
      ),
    );
  }
}

/// The 270° setpoint arc: a faint track, the set part shaded through
/// [colors] cold to hot, a ring of ticks inside it, and a glowing knob at
/// the setpoint.
class _DialPainter extends CustomPainter {
  _DialPainter({required this.value, required this.colors, required this.unit});

  final double value;
  final List<Color> colors;
  final double unit;

  /// The colour at [f] (0–1) along [colors].
  Color _at(double f) {
    final x = f.clamp(0.0, 1.0) * (colors.length - 1);
    final i = min(x.floor(), colors.length - 2);
    return Color.lerp(colors[i], colors[i + 1], x - i)!;
  }

  static const _start = 3 * pi / 4;
  static const _sweep = 3 * pi / 2;
  static const _ticks = 36;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.width / 2);
    final r = size.width / 2 - unit * 0.8;
    final rect = Rect.fromCircle(center: c, radius: r);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = unit * 0.3;
    canvas.drawArc(
      rect,
      _start,
      _sweep,
      false,
      stroke..color = _white.withValues(alpha: 0.10),
    );
    canvas.drawArc(
      rect,
      _start,
      _sweep * value,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = unit * 0.3
        ..shader = SweepGradient(
          endAngle: _sweep,
          colors: colors,
          transform: const GradientRotation(_start),
        ).createShader(rect),
    );

    final tick = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = unit * 0.16;
    for (var i = 0; i <= _ticks; i++) {
      final f = i / _ticks;
      final a = _start + _sweep * f;
      final dir = Offset(cos(a), sin(a));
      tick.color = f <= value + 1e-6
          ? _at(f).withValues(alpha: 0.85)
          : _white.withValues(alpha: 0.12);
      canvas.drawLine(
        c + dir * (r - unit * 1.2),
        c + dir * (r - unit * (i % 3 == 0 ? 2.1 : 1.7)),
        tick,
      );
    }

    final knobColor = _at(value);
    final knob =
        c +
        Offset(cos(_start + _sweep * value), sin(_start + _sweep * value)) * r;
    canvas.drawCircle(
      knob,
      unit * 0.9,
      Paint()
        ..color = knobColor.withValues(alpha: 0.4)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, unit * 0.6),
    );
    canvas.drawCircle(knob, unit * 0.6, Paint()..color = knobColor);
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.value != value || !listEquals(old.colors, colors) || old.unit != unit;
}
