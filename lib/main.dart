import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'gree.dart';
import 'lights.dart';

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
  bool _showHint = true;

  final _lights = configuredLights();
  final _acs = configuredAcs();
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopTimers();
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

            // HH:MM on one line both ways up — standing, that leaves the
            // panel's height for the lights and AC. Overshoots on purpose:
            // the FittedBox below scales the column down until it fills its
            // box, and scaleDown never scales up.
            final digitSize = min(w * 0.55, h * 1.15);
            // The time's own width. Measured at this tracking: DSEG7
            // advances 0.676 * digitSize per digit, 0.196 for the colon.
            final timeWidth = digitSize * 2.902;
            // Everything under the time is held to this — otherwise a long
            // date sets the width and the digits shrink to suit. Narrower
            // than the time on purpose: a full-width rule reads as an
            // underline rather than a divider.
            final faceWidth = timeWidth * 0.61;
            final gap = digitSize * 0.07;
            final tightGap = gap * 0.64; // Seconds hug the time.
            // The panel sizes off the screen's short side, so it's the same
            // size whichever way up the phone is.
            final barSpan = min(w, h);
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
              fontSize: digitSize * 0.14,
              fontWeight: FontWeight.w600,
              letterSpacing: digitSize * 0.025,
            );

            final time = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _segments(hh, digitStyle),
                // Lit either way on a real panel, so no layer behind.
                Text(':', style: digitStyle),
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
                              // Standing, the time spans the full width to
                              // line up with the panel's edges under it.
                              child: FractionallySizedBox(
                                widthFactor: landscape ? _faceScale : 1,
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
                                                SizedBox(
                                                  width: digitSize * 0.05,
                                                ),
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
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
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
                                                text:
                                                    _weekdays[_now.weekday - 1]
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
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                            if (_lights.isNotEmpty || _acs.isNotEmpty)
                              Padding(
                                padding: landscape
                                    ? EdgeInsets.only(left: barSpan * 0.04)
                                    : EdgeInsets.only(top: barSpan * 0.04),
                                // Scrolls once there's more than fits. On
                                // its side the row bounds its height;
                                // standing, it stops short of squeezing
                                // the clock below full width (~0.58 of
                                // the width, at the 0.8 height factor).
                                child: ConstrainedBox(
                                  constraints: BoxConstraints(
                                    maxHeight: landscape
                                        ? double.infinity
                                        : max(
                                            0.0,
                                            h -
                                                2 * (driftY + 4) -
                                                barSpan * 0.04 -
                                                (w - 2 * (driftX + 4)) * 0.58,
                                          ),
                                  ),
                                  child: SingleChildScrollView(
                                    child: LightsPanel(
                                      lights: _lights,
                                      acs: _acs,
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

/// The lights half of the dashboard: a tile per configured light with its
/// live state and its buttons. It polls every 15 s while the app is on
/// screen — the phone lives on the charger, so that's not worth saving.
class LightsPanel extends StatefulWidget {
  const LightsPanel({
    super.key,
    required this.lights,
    required this.width,
    required this.unit,
    this.acs = const [],
  });

  final List<Light> lights;
  final double width;

  /// The air conditioners, one card each under the light tiles.
  final List<GreeAc> acs;

  /// Base text size; the tiles are proportioned off it.
  final double unit;

  @override
  State<LightsPanel> createState() => _LightsPanelState();
}

class _LightsPanelState extends State<LightsPanel> with WidgetsBindingObserver {
  final _states = <Light, LightState>{};
  final _offline = <Light>{};
  final _busy = <Light>{};
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
    super.dispose();
  }

  void _refreshAll() {
    for (final light in widget.lights) {
      if (!_busy.contains(light)) _refresh(light);
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

  void _allOff() {
    for (final light in widget.lights) {
      if (_states[light]?.on == true) {
        _run(
          light,
          () => light.setPower(false),
          LightState(false, _states[light]?.brightness),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final u = widget.unit;
    final gap = u * 0.8;
    // Square tiles, two to a row.
    final tile = (widget.width - gap) / 2;
    final anyOn = _states.values.any((s) => s.on);
    return SizedBox(
      width: widget.width,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.home_rounded,
                size: u * 1.2,
                color: _white.withValues(alpha: 0.45),
              ),
              SizedBox(width: u * 0.5),
              Text(
                'LIGHTS',
                style: TextStyle(
                  color: _white.withValues(alpha: 0.45),
                  fontSize: u * 0.85,
                  fontWeight: FontWeight.w600,
                  letterSpacing: u * 0.2,
                ),
              ),
              const Spacer(),
              // One tap for bedtime.
              _chip(
                Icons.power_settings_new_rounded,
                'ALL OFF',
                active: false,
                color: _white,
                enabled: anyOn,
                onTap: _allOff,
              ),
            ],
          ),
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
                  AcPanel(ac: ac, width: tile, unit: u),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// A square tile: one big power button across the top and, for a
  /// dimmable light, a 2×2 grid of brightness presets under it.
  Widget _tile(Light light, double size) {
    final u = widget.unit;
    final glow = _glowFor(light);
    final state = _states[light];
    final on = state?.on == true;
    final level = state?.brightness;
    final offline = _offline.contains(light);
    final busy = _busy.contains(light);
    // On/off and the level already show on the lit buttons; only say
    // something when the tile can't show either.
    final status = offline
        ? 'Offline'
        : state == null
        ? 'Connecting…'
        : null;
    final accent = offline
        ? _red
        : (on ? glow : _white.withValues(alpha: 0.45));

    Widget preset(int pct) {
      // The level set elsewhere (the bulb's own app, a wall switch) rarely
      // lands on a preset, so light up whichever is nearest.
      final active =
          on &&
          level != null &&
          _presets.reduce(
                (a, b) => (a - level).abs() <= (b - level).abs() ? a : b,
              ) ==
              pct;
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: busy
              ? null
              : () => _run(
                  light,
                  () => light.setBrightness(pct),
                  LightState(true, pct),
                ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            height: u * 2.5,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? glow : _glassRaised,
              border: Border.all(color: active ? glow : _glassEdge),
              borderRadius: BorderRadius.circular(u * 1.25),
            ),
            child: Text(
              '$pct%',
              style: TextStyle(
                color: active
                    ? Colors.black
                    : _white.withValues(alpha: busy ? 0.3 : 0.8),
                fontSize: u * 0.95,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      );
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: size,
      height: size,
      padding: EdgeInsets.all(u * 1.1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(u * 1.8),
        color: on ? null : _glass,
        gradient: on
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  glow.withValues(alpha: 0.24),
                  glow.withValues(alpha: 0.05),
                ],
              )
            : null,
        border: Border.all(
          color: on
              ? glow.withValues(alpha: 0.55)
              : offline
              ? _red.withValues(alpha: 0.35)
              : _glassEdge,
        ),
        boxShadow: on
            ? [
                BoxShadow(
                  color: glow.withValues(alpha: 0.18),
                  blurRadius: u * 2,
                ),
              ]
            : null,
      ),
      child: Column(
        children: [
          // Power fills the top: no name, the tile's colour says which
          // light it is (off, the icon keeps a hint of that colour).
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: busy
                  ? null
                  : () => _run(
                      light,
                      () => light.setPower(!on),
                      LightState(!on, level),
                    ),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: on ? glow : _glassRaised,
                  borderRadius: BorderRadius.circular(u * 1.25),
                  border: Border.all(
                    color: on
                        ? glow
                        : offline
                        ? _red.withValues(alpha: 0.35)
                        : _glassEdge,
                  ),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    busy
                        ? SizedBox.square(
                            dimension: u * 2.4,
                            child: CircularProgressIndicator(
                              strokeWidth: u * 0.2,
                              color: on ? Colors.black : _white,
                            ),
                          )
                        : Icon(
                            offline
                                ? Icons.wifi_off_rounded
                                : Icons.power_settings_new_rounded,
                            size: u * 3,
                            color: on
                                ? Colors.black
                                : offline
                                ? _red
                                : glow.withValues(alpha: 0.6),
                          ),
                    if (status != null)
                      Text(
                        status,
                        style: TextStyle(color: accent, fontSize: u * 0.8),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (light.dimmable) SizedBox(height: u * 0.6),
          if (light.dimmable) ...[
            Row(
              children: [
                preset(1),
                SizedBox(width: u * 0.6),
                preset(25),
              ],
            ),
            SizedBox(height: u * 0.6),
            Row(
              children: [
                preset(50),
                SizedBox(width: u * 0.6),
                preset(100),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// A pill with an icon; [active] fills it in [color] to mark the setting
  /// the bulb is at.
  Widget _chip(
    IconData icon,
    String label, {
    required bool active,
    required Color color,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final u = widget.unit;
    final fg = active
        ? Colors.black
        : _white.withValues(alpha: enabled ? 0.75 : 0.3);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        height: u * 2.6,
        padding: EdgeInsets.symmetric(horizontal: u * 0.9),
        decoration: BoxDecoration(
          color: active ? color : _glassRaised,
          border: Border.all(
            color: active ? color : _white.withValues(alpha: 0.12),
          ),
          borderRadius: BorderRadius.circular(u * 1.3),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: u * 1.2, color: fg),
            SizedBox(width: u * 0.4),
            Text(
              label,
              style: TextStyle(
                color: fg,
                fontSize: u * 0.85,
                fontWeight: FontWeight.w600,
                letterSpacing: u * 0.06,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// The frosted-card surfaces — white over black at low opacity, the
// reference's glass without the photo behind it.
final _glass = _white.withValues(alpha: 0.05);
final _glassRaised = _white.withValues(alpha: 0.08);
final _glassEdge = _white.withValues(alpha: 0.10);

/// A light's glow colour, read off its name: cool white for a "white" or
/// "cool" light, warm amber for anything else. Only the lights get colour
/// like this — the clock keeps its white and red.
Color _glowFor(Light light) {
  final name = light.name.toLowerCase();
  return name.contains('white') || name.contains('cool')
      ? const Color(0xFFD6E6FF)
      : const Color(0xFFFFB04A);
}

/// The air conditioner as one wide frosted card under the lights — a dial
/// for the setpoint (drag it, or tap − / +) with the room temperature in
/// it, and a power switch. Polls every 15 s while the app is on screen.
class AcPanel extends StatefulWidget {
  const AcPanel({
    super.key,
    required this.ac,
    required this.width,
    required this.unit,
  });

  final GreeAc ac;

  /// The tile's width; it's 1.3× as tall.
  final double width;
  final double unit;

  @override
  State<AcPanel> createState() => _AcPanelState();
}

class _AcPanelState extends State<AcPanel> with WidgetsBindingObserver {
  // The reference's olive-yellow, for the arc, ticks and switch.
  static const _accent = Color(0xFFE3DC5B);

  AcState? _state;
  bool _offline = false;
  bool _busy = false;

  /// A setpoint being dialled in, sent once the user stops moving it.
  int? _pending;
  Timer? _poll;
  Timer? _send;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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

  /// The setpoint under a touch at [p] on a dial [size] wide: the arc runs
  /// 270° clockwise from bottom-left, and touches in the gap snap to the
  /// nearer end.
  int _tempAt(Offset p, double size) {
    final c = Offset(size / 2, size / 2);
    final deg = atan2(p.dy - c.dy, p.dx - c.dx) * 180 / pi;
    var along = (deg - 135 + 360) % 360;
    if (along > 270) along = along > 315 ? 0 : 270;
    return acMinTemp + (along / 270 * (acMaxTemp - acMinTemp)).round();
  }

  /// A tile beside the other AC's: name and mode top-left, power top-right,
  /// the setpoint dial in the middle, and − / room temp / + along the foot.
  /// A little taller than the light squares so the dial has room.
  @override
  Widget build(BuildContext context) {
    final u = widget.unit;
    final width = widget.width;
    final height = width * 1.3;
    final state = _state;
    final on = state?.on == true;
    final temp = _pending ?? state?.setTemp ?? 24;
    final caption = _offline
        ? 'Offline'
        : state == null
        ? 'Connecting…'
        : !on
        ? 'Off'
        : const [
                'Auto',
                'Cooling',
                'Drying',
                'Fan',
                'Heating',
              ].elementAtOrNull(state.mode) ??
              'On';
    final room = state?.roomTemp;
    final pad = u * 1.1;
    // The dial takes the middle: what's left of the height between the
    // header (the power circle) and the − / + row, capped by the width.
    final dialSize = min(
      width - 2 * pad,
      (height - 2 * pad - u * 3.2 - u * 2.6 - u * 0.8) / 0.86,
    );

    Widget roundButton(IconData icon, VoidCallback onTap) => GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        width: u * 2.6,
        height: u * 2.6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _glassRaised,
          border: Border.all(color: _glassEdge),
        ),
        child: Icon(icon, size: u * 1.3, color: _white.withValues(alpha: 0.85)),
      ),
    );

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: width,
      height: height,
      padding: EdgeInsets.all(pad),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(u * 1.8),
        color: on ? null : _glass,
        gradient: on
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  _accent.withValues(alpha: 0.16),
                  _accent.withValues(alpha: 0.03),
                ],
              )
            : null,
        border: Border.all(
          color: on
              ? _accent.withValues(alpha: 0.45)
              : _offline
              ? _red.withValues(alpha: 0.35)
              : _glassEdge,
        ),
      ),
      child: Column(
        children: [
          Row(
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
                    Text(
                      caption,
                      style: TextStyle(
                        color: _offline
                            ? _red
                            : on
                            ? _accent
                            : _white.withValues(alpha: 0.55),
                        fontSize: u * 0.8,
                      ),
                    ),
                  ],
                ),
              ),
              // Power, the same circle as on the light tiles.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _busy || state == null ? null : _togglePower,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: u * 3.2,
                  height: u * 3.2,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: on ? _accent : _glassRaised,
                    border: Border.all(
                      color: on ? _accent : _white.withValues(alpha: 0.18),
                    ),
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
                          color: on
                              ? Colors.black
                              : _white.withValues(alpha: 0.7),
                        ),
                ),
              ),
            ],
          ),
          const Spacer(),
          // The dial. Drag along it (either axis — so the dimmer swipe
          // doesn't steal the touch) or tap a point on it.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _dial(_tempAt(d.localPosition, dialSize)),
            onHorizontalDragUpdate: (d) =>
                _dial(_tempAt(d.localPosition, dialSize)),
            onVerticalDragUpdate: (d) =>
                _dial(_tempAt(d.localPosition, dialSize)),
            child: SizedBox(
              width: dialSize,
              height: dialSize * 0.86,
              child: CustomPaint(
                painter: _DialPainter(
                  value: (temp - acMinTemp) / (acMaxTemp - acMinTemp),
                  accent: on ? _accent : _white.withValues(alpha: 0.3),
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
                        fontSize: u * 2.3,
                        fontWeight: FontWeight.w300,
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
                child: Text(
                  room == null ? '' : 'Room $room°',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(
                    color: _white.withValues(alpha: 0.55),
                    fontSize: u * 0.75,
                  ),
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

/// The 270° setpoint arc: a faint track, the filled part in the accent,
/// a ring of ticks inside it, and a glowing knob at the setpoint.
class _DialPainter extends CustomPainter {
  _DialPainter({required this.value, required this.accent, required this.unit});

  final double value;
  final Color accent;
  final double unit;

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
    canvas.drawArc(rect, _start, _sweep * value, false, stroke..color = accent);

    final tick = Paint()
      ..strokeCap = StrokeCap.round
      ..strokeWidth = unit * 0.16;
    for (var i = 0; i <= _ticks; i++) {
      final f = i / _ticks;
      final a = _start + _sweep * f;
      final dir = Offset(cos(a), sin(a));
      tick.color = f <= value + 1e-6
          ? accent.withValues(alpha: 0.85)
          : _white.withValues(alpha: 0.15);
      canvas.drawLine(
        c + dir * (r - unit * 1.2),
        c + dir * (r - unit * (i % 3 == 0 ? 2.1 : 1.7)),
        tick,
      );
    }

    final knob =
        c +
        Offset(cos(_start + _sweep * value), sin(_start + _sweep * value)) * r;
    canvas.drawCircle(
      knob,
      unit * 0.9,
      Paint()
        ..color = accent.withValues(alpha: 0.35)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, unit * 0.6),
    );
    canvas.drawCircle(knob, unit * 0.6, Paint()..color = accent);
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.value != value || old.accent != accent || old.unit != unit;
}
