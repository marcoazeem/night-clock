import 'dart:async';
import 'dart:math';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const NightClockApp());
}

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

class _FontSpec {
  const _FontSpec({
    this.family,
    this.scale = 1.0,
    this.height = 0.85,
    this.tracking = -0.02,
    this.variations,
  });

  final String? family; // null = platform default (Roboto)
  final double scale; // size multiplier so every font fills similarly
  final double height;
  final double tracking; // letter spacing as a fraction of font size
  final List<FontVariation>? variations;
}

class _ClockScreenState extends State<ClockScreen>
    with WidgetsBindingObserver {
  static const _themes = [
    Color(0xFFFF453A), // red
    Color(0xFFFF9F0A), // amber
    Color(0xFF30D158), // green
    Color(0xFF64D2FF), // cyan
    Color(0xFFE8E8E8), // white
  ];
  static const _fonts = [
    _FontSpec(), // Roboto
    _FontSpec(
      family: 'Doto', // Nothing-style round dot matrix
      scale: 0.95,
      tracking: 0,
      variations: [FontVariation('ROND', 100), FontVariation('wght', 800)],
    ),
    _FontSpec(family: 'DSEG7', scale: 0.78, height: 1.0, tracking: 0.04),
  ];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  int _themeIndex = 0;
  int _fontIndex = 0;
  double _dim = 0.55;
  bool _use24h = false;
  bool _showSeconds = false;

  DateTime _now = DateTime.now();
  Offset _drift = Offset.zero;
  int _batteryLevel = -1;
  bool _charging = false;
  bool _showHint = true;

  final _battery = Battery();
  final _random = Random();
  Timer? _tick;
  Timer? _driftTimer;
  StreamSubscription<BatteryState>? _batterySub;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WakelockPlus.enable().catchError((_) {});
    _loadSettings();
    _startTimers();
    _updateBatteryLevel();
    _batterySub = _battery.onBatteryStateChanged.listen((state) {
      setState(() {
        _charging =
            state == BatteryState.charging || state == BatteryState.full;
      });
      _updateBatteryLevel();
    }, onError: (_) {});

    Future.delayed(const Duration(seconds: 8), () {
      if (mounted) setState(() => _showHint = false);
    });
  }

  void _startTimers() {
    _scheduleTick();
    // AMOLED burn-in protection: shift the clock a few pixels every minute.
    _driftTimer?.cancel();
    _driftTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      setState(() {
        _drift = Offset(
          _random.nextDouble() * 80 - 40,
          _random.nextDouble() * 40 - 20,
        );
      });
      _updateBatteryLevel();
    });
  }

  void _stopTimers() {
    _tick?.cancel();
    _driftTimer?.cancel();
  }

  // Redraw only at the next second or minute boundary — with seconds hidden
  // the clock renders one frame per minute instead of one per second.
  void _scheduleTick() {
    _tick?.cancel();
    final now = DateTime.now();
    final delayMs = _showSeconds
        ? 1000 - now.millisecond
        : (60 - now.second) * 1000 - now.millisecond;
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
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Not visible — stop burning CPU on clock updates.
      _stopTimers();
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
      _themeIndex = (_prefs!.getInt('theme') ?? 0) % _themes.length;
      _fontIndex = (_prefs!.getInt('font') ?? 0) % _fonts.length;
      _dim = _prefs!.getDouble('dim') ?? 0.55;
      _use24h = _prefs!.getBool('use24h') ?? false;
      _showSeconds = _prefs!.getBool('seconds') ?? false;
    });
    _scheduleTick(); // Cadence depends on whether seconds are shown.
  }

  void _saveSettings() {
    _prefs?.setInt('theme', _themeIndex);
    _prefs?.setInt('font', _fontIndex);
    _prefs?.setDouble('dim', _dim);
    _prefs?.setBool('use24h', _use24h);
    _prefs?.setBool('seconds', _showSeconds);
  }

  static const _weekdayLetters = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

  Widget _buildCalendar(Color color, double w, double h) {
    final year = _now.year;
    final month = _now.month;
    final today = _now.day;
    final leading = DateTime(year, month, 1).weekday % 7; // Sunday-first grid.
    final daysInMonth = DateTime(year, month + 1, 0).day;
    final cell = min(w * 0.4 / 7 * 0.82, h * 0.115);

    final headerStyle = TextStyle(
      color: color.withValues(alpha: 0.75),
      fontSize: cell * 0.48,
      fontWeight: FontWeight.w600,
      letterSpacing: cell * 0.06,
    );
    final letterStyle = TextStyle(
      color: color.withValues(alpha: 0.35),
      fontSize: cell * 0.36,
      fontWeight: FontWeight.w600,
    );
    final dayStyle = TextStyle(
      color: color.withValues(alpha: 0.7),
      fontSize: cell * 0.42,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    Widget cellBox(Widget? child) =>
        SizedBox(width: cell, height: cell, child: Center(child: child));

    final rows = <Widget>[
      Padding(
        padding: EdgeInsets.only(bottom: cell * 0.35),
        child: Text(
          '${_months[month - 1]} $year'.toUpperCase(),
          style: headerStyle,
        ),
      ),
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final letter in _weekdayLetters)
            cellBox(Text(letter, style: letterStyle)),
        ],
      ),
    ];

    final totalCells = leading + daysInMonth;
    for (var start = 0; start < totalCells; start += 7) {
      rows.add(Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = start; i < start + 7; i++)
            if (i < leading || i >= totalCells)
              cellBox(null)
            else if (i - leading + 1 == today)
              cellBox(Container(
                width: cell * 0.85,
                height: cell * 0.85,
                alignment: Alignment.center,
                decoration:
                    BoxDecoration(color: color, shape: BoxShape.circle),
                child: Text(
                  '${i - leading + 1}',
                  style: dayStyle.copyWith(
                    color: Colors.black,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ))
            else
              cellBox(Text('${i - leading + 1}', style: dayStyle)),
        ],
      ));
    }

    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }

  Future<void> _updateBatteryLevel() async {
    try {
      final level = await _battery.batteryLevel;
      if (mounted) setState(() => _batteryLevel = level);
    } catch (_) {
      // Battery info unavailable; indicator stays hidden.
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopTimers();
    _batterySub?.cancel();
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = _themes[_themeIndex];
    final hour24 = _now.hour;
    final hour = _use24h ? hour24 : (hour24 % 12 == 0 ? 12 : hour24 % 12);
    final hh = hour.toString().padLeft(2, '0');
    final mm = _now.minute.toString().padLeft(2, '0');
    final ss = _now.second.toString().padLeft(2, '0');
    final ampm = hour24 >= 12 ? 'PM' : 'AM';
    final date =
        '${_weekdays[_now.weekday - 1]}, ${_months[_now.month - 1]} ${_now.day}';

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() {
          _themeIndex = (_themeIndex + 1) % _themes.length;
          _saveSettings();
        }),
        onDoubleTap: () => setState(() {
          _showSeconds = !_showSeconds;
          _saveSettings();
          _scheduleTick();
        }),
        onLongPress: () => setState(() {
          _use24h = !_use24h;
          _saveSettings();
        }),
        onVerticalDragUpdate: (details) => setState(() {
          _dim = (_dim - details.delta.dy / 600).clamp(0.15, 1.0);
        }),
        onVerticalDragEnd: (_) => _saveSettings(),
        onHorizontalDragEnd: (details) => setState(() {
          final velocity = details.primaryVelocity ?? 0;
          _fontIndex = velocity < 0
              ? (_fontIndex + 1) % _fonts.length
              : (_fontIndex + _fonts.length - 1) % _fonts.length;
          _saveSettings();
        }),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            final digitSize = min(w * 0.185, h * 0.50);
            final font = _fonts[_fontIndex];
            final digitStyle = TextStyle(
              color: color,
              fontFamily: font.family,
              fontSize: digitSize * font.scale,
              fontWeight: FontWeight.w700,
              height: font.height,
              letterSpacing: digitSize * font.tracking,
              fontVariations: font.variations,
              fontFeatures: const [FontFeature.tabularFigures()],
            );
            final smallStyle = TextStyle(
              color: color.withValues(alpha: 0.55),
              fontSize: digitSize * 0.085,
              letterSpacing: digitSize * 0.012,
            );

            // A plain translate: the drift jump costs one frame, where an
            // animated slide would render ~120 frames every minute.
            return Transform.translate(
              offset: _drift,
              child: Opacity(
                opacity: _dim,
                child: Stack(
                  children: [
                    Center(
                      child: Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(
                                            text: '$hh:$mm', style: digitStyle),
                                        if (_showSeconds)
                                          TextSpan(
                                            text: ' $ss',
                                            style: digitStyle.copyWith(
                                              fontSize: digitSize * 0.28,
                                              fontWeight: FontWeight.w600,
                                              color:
                                                  color.withValues(alpha: 0.5),
                                            ),
                                          ),
                                        if (!_use24h)
                                          TextSpan(
                                              text: ' $ampm',
                                              style: smallStyle),
                                      ],
                                    ),
                                  ),
                                  Padding(
                                    padding: EdgeInsets.only(top: h * 0.06),
                                    child: Text(date.toUpperCase(),
                                        style: smallStyle),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Expanded(
                            flex: 2,
                            child: Center(
                              child: _buildCalendar(color, w, h),
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_batteryLevel >= 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: h * 0.05,
                        child: Text(
                          '${_charging ? '⚡ ' : ''}$_batteryLevel%',
                          textAlign: TextAlign.center,
                          style: smallStyle.copyWith(
                            color: color.withValues(alpha: 0.35),
                            fontSize: digitSize * 0.065,
                          ),
                        ),
                      ),
                    if (_showHint)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: h * 0.04,
                        child: Text(
                          'tap: colour  ·  hold: 12/24h  ·  double-tap: seconds\nswipe up/down: dim  ·  swipe left/right: font',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.35),
                            fontSize: 13,
                            height: 1.6,
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
    );
  }
}
