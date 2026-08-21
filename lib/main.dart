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
        TextSpan(
          text: ch,
          style: ch == '1' ? TextStyle(color: red) : null,
        ),
    ],
  );
}

/// How brightly the unlit segments glow, relative to the digit's own
/// opacity. A real 7-segment panel shows every segment faintly, lit or not.
const _segmentOff = 0.11;

/// The digits over their own unlit segments. DSEG7 is monospaced and "8"
/// drives all seven segments, so an all-8s layer of the same style lines up
/// exactly behind [text].
Widget _segments(String text, TextStyle style) {
  return Stack(
    children: [
      Text(
        '8' * text.length,
        style: style.copyWith(
          color: _white.withValues(alpha: _segmentOff * (style.color?.a ?? 1)),
        ),
      ),
      Text.rich(_redOnes(text, style)),
    ],
  );
}

/// How much of the room it's given the face actually fills. This is the size
/// dial, not `digitSize` — that deliberately overshoots and the `FittedBox`
/// scales it back to whatever box it's handed, so shrinking it changes
/// nothing. Edge to edge was too big both ways up; the user asked for 20%
/// less, first standing and then on its side.
const _faceScale = 0.8;

/// Holds [child] to [width], shrinking it if it would be wider. The time is
/// what should set the face width, stacked or across; without this a long
/// date or a wide platform font would, and the digits would shrink to suit.
Widget _capWidth(double width, Widget child) {
  return SizedBox(
    width: width,
    child: FittedBox(fit: BoxFit.scaleDown, child: child),
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
        // Unit offsets in [-1, 1]; build scales them to the drift range for
        // whichever way up the phone is.
        _drift = Offset(
          _random.nextDouble() * 2 - 1,
          _random.nextDouble() * 2 - 1,
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

  /// The bar's thickness, off the panel's short side so it stays the same
  /// size whichever way up the phone is. [_buildBatteryBar] and the gap kept
  /// clear for it in [build] both size off this.
  double _barHeight(double span) => max(3.0, span * 0.014);

  /// A plain capsule bar — no battery outline, no percentage. The fill length
  /// is the charge and its colour is the warning; a bolt appears when charging.
  Widget _buildBatteryBar(double span) {
    final level = _batteryLevel.clamp(0, 100);
    final barH = _barHeight(span);
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
          width: span * 0.48,
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
            // The stand holds the phone upright on the charger; turned on
            // its side it slides off the coil and stops charging, so both
            // ways up have to read as a clock.
            final landscape = w > h;

            // Burn-in drift wanders further along the panel's long axis.
            final driftX = landscape ? 40.0 : 20.0;
            final driftY = landscape ? 20.0 : 40.0;

            // Portrait stacks HH over MM, so two glyphs — not five — set
            // the width; landscape has room for HH:MM across. Both
            // overshoot on purpose: the FittedBox below scales the column
            // down until it fills the panel, and scaleDown never scales up.
            final digitSize = landscape
                ? min(w * 0.55, h * 1.15)
                : min(w * 1.15, h * 0.55);
            // The time's own width. Measured at this tracking: DSEG7
            // advances 0.676 * digitSize per digit, 0.196 for the colon.
            final timeWidth = digitSize * (landscape ? 2.902 : 1.353);
            // Everything under the time is held to this — otherwise a long
            // date sets the width and the digits shrink to suit. Narrower
            // than the time on purpose: a full-width rule reads as an
            // underline rather than a divider.
            final faceWidth = timeWidth * 0.61;
            // Landscape is short, so the rows under the time close up.
            final gap = digitSize * (landscape ? 0.07 : 0.11);
            final tightGap = gap * 0.64; // Seconds hug the time.
            // The bar sits off the panel's short side — the same size and
            // the same distance from the edge whichever way up the phone is.
            final barSpan = min(w, h);
            final barInset = barSpan * 0.05;
            // Height kept clear at the foot of the panel, so a face that runs
            // out of room can't grow down into the bar. The allowance is for
            // the bolt, which is the tallest the row ever gets.
            final barZone = _batteryLevel >= 0
                ? barInset + _barHeight(barSpan) * 3.2 + 12
                : 0.0;
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
              fontSize: digitSize * 0.055,
              letterSpacing: digitSize * 0.009,
            );
            final dateStyle = TextStyle(
              fontSize: digitSize * 0.075,
              fontWeight: FontWeight.w600,
              letterSpacing: digitSize * 0.016,
            );

            // Hours over minutes on the narrow panel — worth roughly 2.5x
            // the glyph height one "HH:MM" line would fit. Across the wide
            // one there's room for the whole time on a single line.
            final time = landscape
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _segments(hh, digitStyle),
                      // Lit either way on a real panel, so no layer behind.
                      Text(':', style: digitStyle),
                      _segments(mm, digitStyle),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _segments(hh, digitStyle),
                      SizedBox(height: digitSize * 0.05),
                      _segments(mm, digitStyle),
                    ],
                  );

            // A plain translate: the drift jump costs one frame, where an
            // animated slide would render ~120 frames every minute.
            return Transform.translate(
              offset: Offset(_drift.dx * driftX, _drift.dy * driftY),
              child: Opacity(
                opacity: _pixelOpacity,
                child: Stack(
                  children: [
                    // Inset by the drift range so the face never wanders
                    // off the panel edge, and by the battery bar's height
                    // at the foot so the two can't meet.
                    Positioned.fill(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          driftX + 4,
                          driftY + 4,
                          driftX + 4,
                          driftY + 4 + barZone,
                        ),
                        child: FractionallySizedBox(
                          widthFactor: _faceScale,
                          heightFactor: _faceScale,
                          // scaleDown fits the stack to that box: the time
                          // is what binds, so this fills it without ever
                          // wrapping or clipping.
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                time,
                                if (_showSeconds || !_use24h) ...[
                                  SizedBox(height: tightGap),
                                  _capWidth(
                                    faceWidth,
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        if (_showSeconds)
                                          _segments(
                                            ss,
                                            digitStyle.copyWith(
                                              fontSize: digitSize * 0.12,
                                              fontWeight: FontWeight.w600,
                                              color: _white.withValues(
                                                alpha: 0.5,
                                              ),
                                            ),
                                          ),
                                        if (_showSeconds && !_use24h)
                                          SizedBox(width: digitSize * 0.05),
                                        if (!_use24h)
                                          Text(ampm, style: smallStyle),
                                      ],
                                    ),
                                  ),
                                ],
                                SizedBox(height: gap),
                                Container(
                                  width: faceWidth,
                                  height: max(1.5, digitSize * 0.0045),
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
                                SizedBox(height: gap),
                                _capWidth(
                                  faceWidth,
                                  Text.rich(
                                    TextSpan(
                                      children: [
                                        TextSpan(
                                          text: _weekdays[_now.weekday - 1]
                                              .toUpperCase(),
                                          style: dateStyle.copyWith(
                                            color: _red,
                                          ),
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
                        bottom: barInset,
                        child: Center(child: _buildBatteryBar(barSpan)),
                      ),
                    if (_showHint)
                      Positioned(
                        left: 0,
                        right: 0,
                        // Landscape leaves no headroom over the digits, so
                        // the hint sits right at the edge and on one line.
                        top: landscape ? 4.0 : barSpan * 0.08,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              'hold: 12/24h  ·  double-tap: seconds  ·  swipe: dim',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.35),
                                fontSize: 13,
                              ),
                            ),
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
