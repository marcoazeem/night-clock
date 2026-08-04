# Night Clock

Flutter nightstand clock that turns a spare Galaxy Note 8 into a bedside
display. Landscape-only: big time on the left, current-month calendar with
today circled on the right, true-black background for AMOLED.

## Target device

- Samsung Galaxy Note 8 (SM-N950F), Android 9, usually connected over USB.
  adb serial: `ce0617165451ea26057e` — always pass `-s` (a stale offline
  emulator entry often makes bare `adb` fail with "more than one device").
- Phone renders at HD+ (1480×720); screenshots pulled from it come out at
  that size.
- Do NOT inject input (`adb shell input ...`) — the user often holds the
  phone. Verify visuals with golden tests instead (see below).

## Toolchain & commands

- Flutter at `~/FlutterDev/flutter` (not on PATH — use the full path).
- Android SDK at `~/Library/Android/sdk`.

```sh
~/FlutterDev/flutter/bin/flutter analyze
~/FlutterDev/flutter/bin/flutter test
~/FlutterDev/flutter/bin/flutter build apk --release --split-per-abi
adb -s ce0617165451ea26057e install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
adb -s ce0617165451ea26057e push build/app/outputs/flutter-apk/app-arm64-v8a-release.apk /sdcard/Download/night-clock.apk
```

After every install, also refresh the `/sdcard/Download/night-clock.apk`
copy (the user keeps it for reinstalling without the Mac).

## Architecture (single file: lib/main.dart)

- `_fonts` is the style cycle: 9 `_FontSpec` font entries (each with a
  per-font `scale`/`height`/`tracking` so different faces fill the panel
  similarly) plus 3 `_ClockStyle` faces: `flip` (split-flap cards,
  `_FlipCard` animates the fold), `burst` (`_BurstPainter` dash ring),
  `analog` (`_AnalogPainter`).
- Gestures: tap = colour theme, horizontal swipe = style, vertical swipe =
  dim, long-press = 12/24h, double-tap = seconds. Settings persist via
  SharedPreferences.
- Two-stage dimmer: `_dim` above `_panelFloor` (0.4) drives real
  window-level brightness (screen_brightness plugin, no permissions,
  system setting untouched, reset on pause/dispose, re-asserted on resume
  and post-first-frame); below it the backlight is at hardware floor and
  `_pixelOpacity` fades pixels down to 0.12.
- Battery discipline (do not regress): one redraw per minute when seconds
  are hidden (`_scheduleTick` targets the next boundary), burn-in drift is
  an instant jump (never animate it), all timers stop when the app is not
  visible (`didChangeAppLifecycleState`).
- Burn-in protection: whole display wanders ±40×±20 px each minute.

## Fonts (fonts/)

All bundled with license texts. Nabla is a COLR colour font — it paints
its own gradient and ignores the theme colour; that is expected, not a
bug. `ndot-47-inspired-by-nothing.otf` is a free fan recreation (no formal
license — known small takedown risk in the public repo). DSEG7 has digits
only; never use it for text.

## Verifying visuals without the phone

Write a throwaway golden test, run
`flutter test --update-goldens test/<name>.dart`, Read the PNG, then
delete the test and `test/goldens/`. Notes: the test font (Ahem) renders
text as solid boxes (geometry is still checkable; load real TTFs via
FontLoader when glyphs matter); battery_plus throws MissingPluginException
in tests — filter it via `FlutterError.onError` or keep it out of the
committed test.

## Measured battery reality (Aug 2026)

App CPU cost is ~0.4 mAh per night — software is at the floor; don't chase
further app-side savings. Panel at minimum brightness ≈ 106 mA on this
device. The battery is aged to ~55% health (~1,800 mAh effective), which
is why percentages look large. Real levers: battery replacement or the
charger. Samsung Maximum power saving mode cannot whitelist third-party
apps without root — don't retry that.

## Repo

Public: github.com/marcoazeem/night-clock. Commit and push only when the
user says so (they ask explicitly, usually as "commit and push").
