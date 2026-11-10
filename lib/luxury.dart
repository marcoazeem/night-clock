// The luxury look (Nov 2026, the user approved a mock-up — "very luxury and
// premium"): pure black, warm ivory text, one accent — champagne gold — for
// what's on, thin type, brushed-metal hairline edges, the background clip
// shrunk to a picture strip that fades into the black.
part of 'main.dart';

/// Warm ivory: the clock and anything that reads.
const _ivory = Color(0xFFEDE6DA);

/// Labels and anything off.
const _muted = Color(0xFF8E877C);

/// The one accent: what's on, the room you're in, play.
const _gold = Color(0xFFC8A97E);

/// Thin display face for the time, temperatures and setpoints.
const _jost = 'Jost';

const _weekdaysFull = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _monthsFull = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Small letter-spaced capitals: every label on the luxury face.
TextStyle _caps(
  double size, {
  Color color = _muted,
  double spacing = 0.3,
  FontWeight weight = FontWeight.w400,
}) => TextStyle(
  fontSize: size,
  color: color,
  letterSpacing: size * spacing,
  fontWeight: weight,
  height: 1.2,
);

/// Gold, or its night-mode red.
Color _goldFor(bool night) => _hue(_gold, night);

/// A luxury card: near-black, with a 1 px edge that catches light like
/// brushed metal (brighter at the top, fading down). [lit] (gold when on)
/// warms the edge and the fill; [alert] turns the edge red.
class _LuxCard extends StatelessWidget {
  const _LuxCard({
    required this.child,
    required this.radius,
    this.width,
    this.height,
    this.lit,
    this.alert = false,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final double radius;
  final double? width;
  final double? height;
  final Color? lit;
  final bool alert;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final lit = this.lit;
    final edge = alert
        ? [_red.withValues(alpha: 0.6), _red.withValues(alpha: 0.12)]
        : lit != null
        ? [lit.withValues(alpha: 0.62), lit.withValues(alpha: 0.1)]
        : [_ivory.withValues(alpha: 0.24), _ivory.withValues(alpha: 0.05)];
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: width,
      height: height,
      padding: const EdgeInsets.all(1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: const Alignment(-0.3, -1),
          end: const Alignment(0.3, 1),
          colors: edge,
        ),
      ),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        padding: padding,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius - 1),
          gradient: LinearGradient(
            begin: const Alignment(-0.6, -1),
            end: const Alignment(0.6, 1),
            colors: [
              lit == null
                  ? const Color(0xFF060606)
                  : Color.alphaBlend(
                      lit.withValues(alpha: 0.10),
                      const Color(0xFF060504),
                    ),
              const Color(0xFF020202),
            ],
          ),
        ),
        child: child,
      ),
    );
  }
}

/// The small glowing dot on something that's on.
Widget _luxDot(Color color, double size) => Container(
  width: size,
  height: size,
  decoration: BoxDecoration(
    shape: BoxShape.circle,
    color: color,
    boxShadow: [BoxShadow(color: color, blurRadius: size * 1.6)],
  ),
);

/// The picture: the user's clip for the time and weather (sunny by day,
/// night after dark, rain whenever it rains; the forest on the home page),
/// fading into the black at top and bottom. Only the picture changes with
/// the weather — the rest of the screen stays black (the user asked).
/// Gone in standby, so the OLED is dark and nothing decodes. After dark
/// it's a still, in greyscale (the user asked, 10 Nov 2026).
class _LuxPicture extends StatelessWidget {
  const _LuxPicture({
    required this.clip,
    required this.standby,
    required this.night,
    required this.still,
  });

  final String clip;
  final bool standby;
  final bool night;
  final bool still;

  /// Greyscale: each channel becomes the pixel's luminance.
  static const _grey = ColorFilter.matrix([
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0.2126,
    0.7152,
    0.0722,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);

  @override
  Widget build(BuildContext context) {
    // Fill the strip it's given (the clip's FittedBox would otherwise
    // shrink to its aspect ratio under a loose width).
    return SizedBox.expand(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 1500),
        // Each child fills the strip (the default centres them loosely).
        layoutBuilder: (current, previous) => Stack(
          fit: StackFit.expand,
          children: [...previous, ?current],
        ),
        child: standby || const bool.fromEnvironment('NO_VIDEO')
            ? const SizedBox.expand(key: ValueKey('none'))
            : ShaderMask(
                key: ValueKey('$clip/$still'),
                blendMode: BlendMode.dstIn,
                shaderCallback: (r) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black,
                    Colors.black,
                    Colors.transparent,
                  ],
                  stops: [0, 0.32, 0.66, 1],
                ).createShader(r),
                child: Opacity(
                  opacity: night ? 0.45 : (still ? 0.7 : 0.8),
                  child: still
                      // A frame of the clip (assets/video/<clip>.jpg, made
                      // with ffmpeg beside the clip; gitignored like it).
                      ? ColorFiltered(
                          colorFilter: _grey,
                          child: Image.asset(
                            'assets/video/$clip.jpg',
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: double.infinity,
                            errorBuilder: (_, _, _) => const SizedBox.expand(),
                          ),
                        )
                      : _VideoSky(
                          asset: 'assets/video/$clip.mp4',
                          fallback: const SizedBox.expand(),
                        ),
                ),
              ),
      ),
    );
  }
}

/// The weather icon — Meteocons, animated, except in night mode (and
/// [still]) where it's the still SVG pulled towards the dashboard's red.
Widget _meteocon(Weather w, double size, bool night, {bool still = false}) {
  final name = const bool.fromEnvironment('FORCE_RAIN')
      ? 'rain'
      : const bool.fromEnvironment('FORCE_CLEAR')
      ? 'clear-${w.isDay ? 'day' : 'night'}'
      : w.icon;
  Widget icon = night || still
      ? SvgPicture.asset('assets/weather/$name.svg', width: size, height: size)
      : RepaintBoundary(
          child: Lottie.asset(
            'assets/weather/$name.json',
            width: size,
            height: size,
            fit: BoxFit.contain,
            frameRate: const FrameRate(24),
            errorBuilder: (_, _, _) => SvgPicture.asset(
              'assets/weather/$name.svg',
              width: size,
              height: size,
            ),
          ),
        );
  if (night) {
    icon = ColorFiltered(
      colorFilter: ColorFilter.mode(_hue(_white, true), BlendMode.modulate),
      child: icon,
    );
  }
  return icon;
}

/// A thin tappable icon (− / + / power) with a 44 pt target.
Widget _luxIcon(
  IconData icon,
  double size,
  Color color,
  VoidCallback? onTap, {
  double box = 44,
}) => GestureDetector(
  behavior: HitTestBehavior.opaque,
  onTap: onTap,
  child: SizedBox(
    width: box,
    height: box,
    child: Icon(icon, size: size, color: color, weight: 200),
  ),
);
