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

/// One split-flap card. On a value change the old top half folds down over
/// the new value, then the new bottom half folds into place.
class _FlipCard extends StatefulWidget {
  const _FlipCard({
    required this.value,
    required this.fontSize,
    required this.color,
  });

  final String value;
  final double fontSize;
  final Color color;

  @override
  State<_FlipCard> createState() => _FlipCardState();
}

class _FlipCardState extends State<_FlipCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 400),
  );
  String _prev = '';

  @override
  void initState() {
    super.initState();
    _prev = widget.value;
  }

  @override
  void didUpdateWidget(_FlipCard old) {
    super.didUpdateWidget(old);
    if (old.value != widget.value) {
      _prev = old.value;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cardW = widget.fontSize * 1.4;
    final cardH = widget.fontSize * 1.5;
    final radius = widget.fontSize * 0.12;
    final digitStyle = TextStyle(
      color: widget.color,
      fontSize: widget.fontSize,
      fontWeight: FontWeight.w700,
      height: 1.0,
      fontFeatures: const [FontFeature.tabularFigures()],
    );

    Widget half({required bool top, required String text}) => ClipRect(
      child: Align(
        alignment: top ? Alignment.topCenter : Alignment.bottomCenter,
        heightFactor: 0.5,
        child: Container(
          width: cardW,
          height: cardH,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: const Color(0xFF151517),
            borderRadius: BorderRadius.circular(radius),
          ),
          child: Text.rich(_redOnes(text, digitStyle)),
        ),
      ),
    );

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final animating = _controller.isAnimating;
        final t = animating ? _controller.value : 1.0;
        final prev = animating ? _prev : widget.value;
        final next = widget.value;
        final perspective = Matrix4.identity()..setEntry(3, 2, 0.0015);

        return SizedBox(
          width: cardW,
          height: cardH,
          child: Stack(
            children: [
              Align(
                alignment: Alignment.topCenter,
                child: half(top: true, text: next),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: half(top: false, text: prev),
              ),
              if (animating && t < 0.5)
                Align(
                  alignment: Alignment.topCenter,
                  child: Transform(
                    alignment: Alignment.bottomCenter,
                    transform: perspective.clone()..rotateX(t * pi),
                    child: half(top: true, text: prev),
                  ),
                )
              else if (animating)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Transform(
                    alignment: Alignment.topCenter,
                    transform: perspective.clone()..rotateX(-(1 - t) * pi),
                    child: half(top: false, text: next),
                  ),
                ),
              Align(
                child: Container(
                  width: cardW,
                  height: max(2, widget.fontSize * 0.025),
                  color: Colors.black,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Radiating dashes around the panel border, like a hand-drawn sunburst.
class _BurstPainter extends CustomPainter {
  _BurstPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.75)
      ..strokeWidth = size.shortestSide * 0.006
      ..strokeCap = StrokeCap.round;
    final center = size.center(Offset.zero);
    final rng = Random(7); // fixed seed: identical burst every repaint
    const count = 56;
    final inset = size.shortestSide * 0.05;
    for (var i = 0; i < count; i++) {
      final angle = 2 * pi * i / count;
      final dx = cos(angle);
      final dy = sin(angle);
      final tx = dx.abs() < 1e-6
          ? double.infinity
          : (size.width / 2 - inset) / dx.abs();
      final ty = dy.abs() < 1e-6
          ? double.infinity
          : (size.height / 2 - inset) / dy.abs();
      final t = min(tx, ty);
      final len = size.shortestSide * (0.035 + rng.nextDouble() * 0.055);
      canvas.drawLine(
        center + Offset(dx * (t - len), dy * (t - len)),
        center + Offset(dx * t, dy * t),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BurstPainter old) => old.color != color;
}

/// Minimal analog face: radial ticks, 12/3/6/9 numerals, date by the centre.
class _AnalogPainter extends CustomPainter {
  _AnalogPainter({
    required this.now,
    required this.color,
    required this.accent,
    required this.showSeconds,
    required this.dateText,
  });

  final DateTime now;
  final Color color;
  final Color accent;
  final bool showSeconds;
  final String dateText;

  void _text(
    Canvas canvas,
    String s,
    Offset center,
    double fontSize,
    Color c,
    FontWeight weight,
  ) {
    final tp = TextPainter(
      text: _redOnes(
        s,
        TextStyle(color: c, fontSize: fontSize, fontWeight: weight),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2 * 0.94;

    for (var i = 0; i < 60; i++) {
      final angle = 2 * pi * i / 60 - pi / 2;
      final dir = Offset(cos(angle), sin(angle));
      if (i % 5 == 0) {
        if (i % 15 == 0) continue; // numeral sits here
        canvas.drawLine(
          c + dir * (r * 0.62),
          c + dir * (r * 0.97),
          Paint()
            ..color = color.withValues(alpha: 0.85)
            ..strokeWidth = r * 0.008
            ..strokeCap = StrokeCap.round,
        );
      } else {
        canvas.drawLine(
          c + dir * (r * 0.88),
          c + dir * (r * 0.97),
          Paint()
            ..color = color.withValues(alpha: 0.3)
            ..strokeWidth = r * 0.005
            ..strokeCap = StrokeCap.round,
        );
      }
    }
    _text(
      canvas,
      '12',
      c + Offset(0, -r * 0.80),
      r * 0.15,
      color,
      FontWeight.w600,
    );
    _text(
      canvas,
      '3',
      c + Offset(r * 0.80, 0),
      r * 0.15,
      color,
      FontWeight.w600,
    );
    _text(
      canvas,
      '6',
      c + Offset(0, r * 0.80),
      r * 0.15,
      color,
      FontWeight.w600,
    );
    _text(
      canvas,
      '9',
      c + Offset(-r * 0.80, 0),
      r * 0.15,
      color,
      FontWeight.w600,
    );

    _text(
      canvas,
      dateText,
      c + Offset(r * 0.32, 0),
      r * 0.09,
      _red,
      FontWeight.w700,
    );

    final hourAngle =
        2 * pi * ((now.hour % 12) + now.minute / 60) / 12 - pi / 2;
    final minuteAngle = 2 * pi * (now.minute + now.second / 60) / 60 - pi / 2;

    canvas.drawLine(
      c,
      c + Offset(cos(hourAngle), sin(hourAngle)) * (r * 0.48),
      Paint()
        ..color = color
        ..strokeWidth = r * 0.045
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      c,
      c + Offset(cos(minuteAngle), sin(minuteAngle)) * (r * 0.72),
      Paint()
        ..color = color
        ..strokeWidth = r * 0.032
        ..strokeCap = StrokeCap.round,
    );

    if (showSeconds) {
      final secondAngle = 2 * pi * now.second / 60 - pi / 2;
      final dir = Offset(cos(secondAngle), sin(secondAngle));
      canvas.drawLine(
        c - dir * (r * 0.14),
        c + dir * (r * 0.80),
        Paint()
          ..color = accent
          ..strokeWidth = r * 0.012
          ..strokeCap = StrokeCap.round,
      );
    }

    canvas.drawCircle(c, r * 0.035, Paint()..color = Colors.black);
    canvas.drawCircle(
      c,
      r * 0.035,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.014,
    );
  }

  @override
  bool shouldRepaint(_AnalogPainter old) =>
      old.now != now ||
      old.color != color ||
      old.accent != accent ||
      old.showSeconds != showSeconds;
}

enum _ClockStyle { text, flip, burst, analog }

// Nothing-style accents: the date is always red, and every digit "1"
// renders red no matter the theme colour.
const _red = Color(0xFFFF453A);
const _white = Color(0xFFE8E8E8);

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

class _FontSpec {
  const _FontSpec({
    this.family,
    this.scale = 1.0,
    this.height = 0.85,
    this.tracking = -0.02,
    this.variations,
    this.style = _ClockStyle.text,
  });

  final String? family; // null = platform default (Roboto)
  final double scale; // size multiplier so every font fills similarly
  final double height;
  final double tracking; // letter spacing as a fraction of font size
  final List<FontVariation>? variations;
  final _ClockStyle style;
}

class _ClockScreenState extends State<ClockScreen> with WidgetsBindingObserver {
  static const _themes = [
    _red,
    Color(0xFFFF9F0A), // amber
    Color(0xFF30D158), // green
    Color(0xFF64D2FF), // cyan
    _white,
  ];
  static const _fonts = [
    _FontSpec(), // Roboto
    _FontSpec(family: 'NDot', scale: 0.95, tracking: 0), // NDot 47 dot matrix
    _FontSpec(
      family: 'Doto', // round dot matrix, similar style
      scale: 0.95,
      tracking: 0,
      variations: [FontVariation('ROND', 100), FontVariation('wght', 800)],
    ),
    _FontSpec(family: 'DSEG7', scale: 0.78, height: 1.0, tracking: 0.04),
    _FontSpec(
      family: 'Orbitron', // geometric sci-fi, runs wide
      scale: 0.78,
      tracking: 0,
      variations: [FontVariation('wght', 700)],
    ),
    _FontSpec(
      family: 'Oxanium',
      scale: 0.95,
      tracking: 0,
      variations: [FontVariation('wght', 700)],
    ),
    // Colour font: paints its own 3D gradient, theme tint doesn't apply.
    _FontSpec(family: 'Nabla', scale: 0.85, tracking: 0),
    _FontSpec(family: 'BitcountInk', scale: 1.15, tracking: 0),
    _FontSpec(family: 'SairaCondensed', scale: 1.05, tracking: 0),
    _FontSpec(style: _ClockStyle.flip), // split-flap cards
    _FontSpec(style: _ClockStyle.burst), // stacked digits in a dash burst
    _FontSpec(style: _ClockStyle.analog), // minimal analog face
  ];
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

  int _themeIndex = 0;
  int _fontIndex = 0;
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
      _themeIndex = (_prefs!.getInt('theme') ?? 0) % _themes.length;
      _fontIndex = (_prefs!.getInt('font') ?? 0) % _fonts.length;
      _dim = (_prefs!.getDouble('dim') ?? 0.55).clamp(0.0, 1.0);
      _use24h = _prefs!.getBool('use24h') ?? false;
      _showSeconds = _prefs!.getBool('seconds') ?? false;
    });
    _scheduleTick(); // Cadence depends on whether seconds are shown.
    _applyBrightness();
  }

  void _saveSettings() {
    _prefs?.setInt('theme', _themeIndex);
    _prefs?.setInt('font', _fontIndex);
    _prefs?.setDouble('dim', _dim);
    _prefs?.setBool('use24h', _use24h);
    _prefs?.setBool('seconds', _showSeconds);
  }

  Widget _buildFlipTime(
    Color color,
    double digitSize,
    TextStyle smallStyle,
    String hh,
    String mm,
    String ss,
    String ampm,
    double h,
  ) {
    final fs = digitSize * 0.85;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!_use24h)
          Padding(
            padding: EdgeInsets.only(bottom: h * 0.025),
            child: Text(ampm, style: smallStyle),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _FlipCard(value: hh, fontSize: fs, color: color),
            SizedBox(width: fs * 0.12),
            _FlipCard(value: mm, fontSize: fs, color: color),
            if (_showSeconds) ...[
              SizedBox(width: fs * 0.12),
              _FlipCard(value: ss, fontSize: fs * 0.45, color: color),
            ],
          ],
        ),
      ],
    );
  }

  // Accent used by the fun faces: red like the references, unless the theme
  // itself is red — then near-white so the accent still stands out.
  Color get _accent => _themes[_themeIndex] == _red ? _white : _red;

  Widget _buildBurstFace(
    Color color,
    String hh,
    String mm,
    String ss,
    String ampm,
  ) {
    return LayoutBuilder(
      builder: (context, c) {
        final ph = c.maxHeight;
        final fs = min(c.maxWidth * 0.34, ph * 0.30);
        final digitStyle = TextStyle(
          color: color,
          fontSize: fs,
          fontWeight: FontWeight.w800,
          height: 0.9,
          fontFeatures: const [FontFeature.tabularFigures()],
        );
        final dateStyle = TextStyle(
          fontSize: fs * 0.16,
          fontWeight: FontWeight.w800,
          letterSpacing: fs * 0.01,
        );
        return Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(painter: _BurstPainter(color: color)),
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: _weekdays[_now.weekday - 1].toUpperCase(),
                          style: dateStyle.copyWith(color: _red),
                        ),
                        TextSpan(
                          text: ' ${_now.day}',
                          style: dateStyle.copyWith(
                            color: _red.withValues(alpha: 0.9),
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(height: ph * 0.04),
                  Text.rich(_redOnes(hh, digitStyle)),
                  Text.rich(_redOnes(mm, digitStyle)),
                  if (_showSeconds || !_use24h)
                    Padding(
                      padding: EdgeInsets.only(top: ph * 0.02),
                      child: Text.rich(
                        _redOnes(
                          [if (_showSeconds) ss, if (!_use24h) ampm].join('  '),
                          TextStyle(
                            color: color.withValues(alpha: 0.5),
                            fontSize: fs * 0.13,
                            letterSpacing: fs * 0.01,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAnalogFace(Color color) {
    return CustomPaint(
      size: Size.infinite,
      painter: _AnalogPainter(
        now: _now,
        color: color,
        accent: _accent,
        showSeconds: _showSeconds,
        dateText: '${_weekdays[_now.weekday - 1].toUpperCase()} ${_now.day}',
      ),
    );
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

  // Bottom battery badge: an outline pill with a proportional fill, so one
  // glance says whether the phone needs its charger.
  Widget _buildBatteryBadge(Color color, double digitSize) {
    final bh = digitSize * 0.115;
    final warn = _batteryLevel <= 20 && !_charging;
    final line = color.withValues(alpha: 0.45);
    final fill = warn ? _accent.withValues(alpha: 0.8) : line;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: digitSize * 0.24,
          height: bh,
          padding: EdgeInsets.all(bh * 0.15),
          decoration: BoxDecoration(
            border: Border.all(color: line, width: max(1, bh * 0.08)),
            borderRadius: BorderRadius.circular(bh * 0.28),
          ),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: (_batteryLevel / 100).clamp(0.0, 1.0),
              heightFactor: 1,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(bh * 0.12),
                ),
              ),
            ),
          ),
        ),
        Container(
          width: bh * 0.18,
          height: bh * 0.42,
          margin: EdgeInsets.only(left: bh * 0.1),
          decoration: BoxDecoration(
            color: line,
            borderRadius: BorderRadius.circular(bh * 0.1),
          ),
        ),
        SizedBox(width: bh * 0.55),
        Text.rich(
          _redOnes(
            '${_charging ? '⚡ ' : ''}$_batteryLevel%',
            TextStyle(
              color: warn
                  ? _accent.withValues(alpha: 0.8)
                  : color.withValues(alpha: 0.5),
              fontSize: digitSize * 0.075,
              letterSpacing: digitSize * 0.008,
              fontFeatures: const [FontFeature.tabularFigures()],
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
    final color = _themes[_themeIndex];
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
            final digitSize = min(w * 0.23, h * 0.52);
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
                    // Inset by the drift range (±40 × ±20) so the full-screen
                    // faces never wander off the panel edge.
                    Positioned.fill(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 44,
                          vertical: 24,
                        ),
                        child: font.style == _ClockStyle.burst
                            ? _buildBurstFace(color, hh, mm, ss, ampm)
                            : font.style == _ClockStyle.analog
                            ? _buildAnalogFace(color)
                            : Center(
                                // scaleDown keeps the widest fonts on one
                                // line instead of wrapping or clipping.
                                child: FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (font.style == _ClockStyle.flip)
                                        _buildFlipTime(
                                          color,
                                          digitSize,
                                          smallStyle,
                                          hh,
                                          mm,
                                          ss,
                                          ampm,
                                          h,
                                        )
                                      else
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
                                                    color: color.withValues(
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
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
                                          gradient: LinearGradient(
                                            colors: [
                                              color.withValues(alpha: 0),
                                              color.withValues(alpha: 0.55),
                                              color.withValues(alpha: 0),
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
                                              style: dateStyle.copyWith(
                                                color: _red,
                                              ),
                                            ),
                                            TextSpan(
                                              text: '  ·  ',
                                              style: dateStyle.copyWith(
                                                color: _red.withValues(
                                                  alpha: 0.4,
                                                ),
                                              ),
                                            ),
                                            TextSpan(
                                              text:
                                                  '${_months[_now.month - 1]} ${_now.day}'
                                                      .toUpperCase(),
                                              style: dateStyle.copyWith(
                                                color: _red.withValues(
                                                  alpha: 0.9,
                                                ),
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
                        child: Center(
                          child: _buildBatteryBadge(color, digitSize),
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
