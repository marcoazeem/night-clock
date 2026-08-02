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

class _ClockScreenState extends State<ClockScreen> {
  static const _themes = [
    Color(0xFFFF453A), // red
    Color(0xFFFF9F0A), // amber
    Color(0xFF30D158), // green
    Color(0xFF64D2FF), // cyan
    Color(0xFFE8E8E8), // white
  ];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  int _themeIndex = 0;
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
    WakelockPlus.enable().catchError((_) {});
    _loadSettings();

    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() => _now = DateTime.now());
    });

    // AMOLED burn-in protection: drift the clock a few pixels every minute.
    _driftTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      setState(() {
        _drift = Offset(
          _random.nextDouble() * 16 - 8,
          _random.nextDouble() * 28 - 14,
        );
      });
      _updateBatteryLevel();
    });

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

  Future<void> _loadSettings() async {
    try {
      _prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return; // Storage unavailable; run with defaults.
    }
    if (!mounted) return;
    setState(() {
      _themeIndex = _prefs!.getInt('theme') ?? 0;
      _dim = _prefs!.getDouble('dim') ?? 0.55;
      _use24h = _prefs!.getBool('use24h') ?? false;
      _showSeconds = _prefs!.getBool('seconds') ?? false;
    });
  }

  void _saveSettings() {
    _prefs?.setInt('theme', _themeIndex);
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
    _tick?.cancel();
    _driftTimer?.cancel();
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
        }),
        onLongPress: () => setState(() {
          _use24h = !_use24h;
          _saveSettings();
        }),
        onVerticalDragUpdate: (details) => setState(() {
          _dim = (_dim - details.delta.dy / 600).clamp(0.15, 1.0);
        }),
        onVerticalDragEnd: (_) => _saveSettings(),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            final digitSize = min(w * 0.185, h * 0.50);
            final digitStyle = TextStyle(
              color: color,
              fontSize: digitSize,
              fontWeight: FontWeight.w700,
              height: 0.85,
              letterSpacing: -digitSize * 0.02,
              fontFeatures: const [FontFeature.tabularFigures()],
            );
            final smallStyle = TextStyle(
              color: color.withValues(alpha: 0.55),
              fontSize: digitSize * 0.085,
              letterSpacing: digitSize * 0.012,
            );

            return AnimatedContainer(
              duration: const Duration(seconds: 2),
              curve: Curves.easeInOut,
              transform: Matrix4.translationValues(_drift.dx, _drift.dy, 0),
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
                        bottom: h * 0.03,
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
                          'tap: colour  ·  hold: 12/24h\ndouble-tap: seconds  ·  swipe: dim',
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
