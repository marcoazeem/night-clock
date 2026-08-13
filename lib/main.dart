import 'dart:async';
import 'dart:math';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
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

// The whole palette: white type, red for the date and for every digit "1".
const _red = Color(0xFFFF453A);
const _white = Color(0xFFE8E8E8);

// Battery gauge stops — green at full, sliding to red as it drains.
const _battGreen = Color(0xFF30D158);
const _battAmber = Color(0xFFFF9F0A);

/// The 7-segment face. Digits only — never use it for the date or AM/PM.
const _digitFont = 'DSEG7';
const _digitScale = 0.78;
const _digitHeight = 1.0;
const _digitTracking = 0.04;

/// Wraps [text] so each "1" is red, keeping the base style's opacity.
TextSpan _redOnes(String text, TextStyle style) {
  if (!text.contains('1')) return TextSpan(text: text, style: style);
  final red = _red.withValues(alpha: style.color?.a ?? 1.0);
  return TextSpan(
    style: style,
    children: [
      for (final ch in text.split(''))
        TextSpan(text: ch, style: ch == '1' ? TextStyle(color: red) : null),
    ],
  );
}

/// Gauge colour for a charge [level]: green at 100, amber at 50, red at 0,
/// lerped between so the change reads as gradual rather than as three steps.
Color batteryColor(int level) {
  final pct = level.clamp(0, 100) / 100;
  return pct >= 0.5
      ? Color.lerp(_battAmber, _battGreen, (pct - 0.5) / 0.5)!
      : Color.lerp(_red, _battAmber, pct / 0.5)!;
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
  bool _use24h = false;
  bool _showSeconds = false;

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
    // The brightness override needs an attached activity, which isn't there
    // yet during initState — wait for the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyBrightness(force: true);
    });
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
      _use24h = _prefs!.getBool('use24h') ?? false;
      _showSeconds = _prefs!.getBool('seconds') ?? false;
    });
    _scheduleTick(); // Cadence depends on whether seconds are shown.
    _applyBrightness();
  }

  void _saveSettings() {
    _prefs?.setDouble('dim', _dim);
    _prefs?.setBool('use24h', _use24h);
    _prefs?.setBool('seconds', _showSeconds);
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

  /// A plain capsule bar — no battery outline, no percentage. The fill length
  /// is the charge and its colour is the warning; a bolt appears when charging.
  Widget _buildBatteryBar(double digitSize) {
    final level = _batteryLevel.clamp(0, 100);
    final barH = max(3.0, digitSize * 0.045);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_charging) ...[
          Icon(
            Icons.bolt,
            size: barH * 3.2,
            color: _white.withValues(alpha: 0.75),
          ),
          SizedBox(width: barH * 0.6),
        ],
        Container(
          width: digitSize * 1.5,
          height: barH,
          decoration: BoxDecoration(
            color: _white.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(barH),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: level / 100,
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: batteryColor(level),
                  borderRadius: BorderRadius.circular(barH),
                ),
              ),
            ),
          ),
        ),
      ],
    );
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
    _resetBrightness();
    WakelockPlus.disable().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hour24 = _now.hour;
    final hour = _use24h ? hour24 : (hour24 % 12 == 0 ? 12 : hour24 % 12);
    final hh = hour.toString().padLeft(2, '0');
    final mm = _now.minute.toString().padLeft(2, '0');
    final ss = _now.second.toString().padLeft(2, '0');
    final ampm = hour24 >= 12 ? 'PM' : 'AM';

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: () => setState(() {
          _showSeconds = !_showSeconds;
          _saveSettings();
          _scheduleTick();
        }),
        onLongPress: () => setState(() {
          _use24h = !_use24h;
          _saveSettings();
        }),
        onVerticalDragUpdate: (details) {
          setState(() {
            _dim = (_dim - details.delta.dy / 600).clamp(0.0, 1.0);
          });
          _applyBrightness(); // Live, so the swipe reads as one gesture.
        },
        onVerticalDragEnd: (_) {
          _applyBrightness(force: true);
          _saveSettings();
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final h = constraints.maxHeight;
            final digitSize = min(w * 0.23, h * 0.52);
            // DSEG7 covers digits and the colon only; everything else below
            // deliberately falls back to the platform font.
            final digitStyle = TextStyle(
              color: _white,
              fontFamily: _digitFont,
              fontSize: digitSize * _digitScale,
              fontWeight: FontWeight.w700,
              height: _digitHeight,
              letterSpacing: digitSize * _digitTracking,
              fontFeatures: const [FontFeature.tabularFigures()],
            );
            final smallStyle = TextStyle(
              color: _white.withValues(alpha: 0.55),
              fontSize: digitSize * 0.085,
              letterSpacing: digitSize * 0.012,
            );
            final dateStyle = TextStyle(
              fontSize: digitSize * 0.105,
              fontWeight: FontWeight.w600,
              letterSpacing: digitSize * 0.022,
            );

            // A plain translate: the drift jump costs one frame, where an
            // animated slide would render ~120 frames every minute.
            return Transform.translate(
              offset: _drift,
              child: Opacity(
                opacity: _pixelOpacity,
                child: Stack(
                  children: [
                    // Inset by the drift range (±40 × ±20) so the face never
                    // wanders off the panel edge.
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 44,
                          vertical: 24,
                        ),
                        child: Center(
                          // scaleDown keeps the time on one line instead of
                          // wrapping or clipping.
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text.rich(
                                  TextSpan(
                                    children: [
                                      _redOnes('$hh:$mm', digitStyle),
                                      if (_showSeconds)
                                        _redOnes(
                                          ' $ss',
                                          digitStyle.copyWith(
                                            fontSize: digitSize * 0.28,
                                            fontWeight: FontWeight.w600,
                                            color: _white.withValues(
                                              alpha: 0.5,
                                            ),
                                          ),
                                        ),
                                      if (!_use24h)
                                        TextSpan(
                                          text: ' $ampm',
                                          style: smallStyle,
                                        ),
                                    ],
                                  ),
                                ),
                                SizedBox(height: h * 0.055),
                                Container(
                                  width: digitSize * 2.4,
                                  height: max(1.5, digitSize * 0.014),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(2),
                                    gradient: LinearGradient(
                                      colors: [
                                        _white.withValues(alpha: 0),
                                        _white.withValues(alpha: 0.55),
                                        _white.withValues(alpha: 0),
                                      ],
                                    ),
                                  ),
                                ),
                                SizedBox(height: h * 0.055),
                                Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: _weekdays[_now.weekday - 1]
                                            .toUpperCase(),
                                        style: dateStyle.copyWith(color: _red),
                                      ),
                                      TextSpan(
                                        text: '  ·  ',
                                        style: dateStyle.copyWith(
                                          color: _red.withValues(alpha: 0.4),
                                        ),
                                      ),
                                      TextSpan(
                                        text:
                                            '${_months[_now.month - 1]} ${_now.day}'
                                                .toUpperCase(),
                                        style: dateStyle.copyWith(
                                          color: _red.withValues(alpha: 0.9),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (_batteryLevel >= 0)
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: h * 0.05,
                        child: Center(child: _buildBatteryBar(digitSize)),
                      ),
                    if (_showHint)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: h * 0.04,
                        child: Text(
                          'hold: 12/24h  ·  double-tap: seconds\nswipe up/down: dim',
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
