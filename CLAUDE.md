# Night Clock

Flutter nightstand clock that turns a spare Galaxy Note 8 into a bedside
display. Landscape-only: the time fills the screen with a fading white
hairline and the date beneath it, plus a battery bar at the bottom, on a
true-black background for AMOLED. (A month calendar used to sit on the
right; the user removed it as redundant — don't reintroduce it.)

Deliberately minimal — the user has stripped this down twice. One font, two
colours, no icon chrome. Don't add faces, themes, or decoration back.

## Target device

- Samsung Galaxy Note 8 (SM-N950F), Android 9, usually connected over USB.
  adb serial: `ce0617165451ea26057e` — always pass `-s` (a stale offline
  emulator entry often makes bare `adb` fail with "more than one device").
- Phone renders at HD+ (1480×720); screenshots pulled from it come out at
  that size.
- Do NOT inject input (`adb shell input ...`) — the user often holds the
  phone. Verify visuals with golden tests instead (see below).
- `adb shell dumpsys battery set level N` does NOT move the in-app gauge:
  battery_plus reads `BATTERY_PROPERTY_CAPACITY` from the HAL, which the
  override bypasses. Verify gauge colours with a golden test instead, and
  note the level is only re-polled once a minute (or on a charge-state
  change), so it lags a forced change either way.

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

- One face only: DSEG7 7-segment digits (`_digitFont` and its
  `_digitScale`/`_digitHeight`/`_digitTracking` constants). The font cycle,
  `_FontSpec`, `_ClockStyle`, and the flip/burst/analog faces were all
  deleted — don't bring them back.
- Two colours only: `_white` for the time, `_red` for the date and for
  every digit "1" (the `_redOnes` helper). The theme cycle and its tap
  gesture are gone. (The date was briefly white; the user asked for red.)
- Gestures: vertical swipe = dim, long-press = 12/24h, double-tap =
  seconds. Settings persist via SharedPreferences. There is no tap or
  horizontal-swipe gesture any more.
- Battery bar: a plain capsule, no outline and no percentage — length is
  the charge, colour comes from `batteryColor()` (green 100 → amber 50 →
  red 0, lerped), with `Icons.bolt` shown only while charging. The user
  explicitly rejected a battery-shaped icon and the % readout.
- Two-stage dimmer: `_dim` above `_panelFloor` (0.4) drives real
  window-level brightness (screen_brightness plugin, no permissions,
  system setting untouched, reset on pause/dispose, re-asserted on resume
  and post-first-frame); below it the backlight is at hardware floor and
  `_pixelOpacity` fades pixels down to 0.12.
- Battery discipline (do not regress): one redraw per minute when seconds
  are hidden (`_scheduleTick` targets the next boundary), burn-in drift is
  an instant jump (never animate it), all timers stop when the app is not
  visible (`didChangeAppLifecycleState`).
- Burn-in protection: whole display wanders ±40×±20 px each minute. The
  face area is inset 44×24 px so that drift never pushes content offscreen,
  and the text face sits in a `FittedBox` (scaleDown) so wide fonts shrink
  instead of wrapping — the test font's square glyphs overflow without it.

## Fonts (fonts/)

Only `DSEG7Classic-Bold.ttf` plus `OFL-DSEG.txt` remain; the other eight
faces and their licenses were deleted when the app went single-font (this
also removed the NDot fan-recreation takedown risk). DSEG7 covers digits
and the colon only — never use it for text, so the date and AM/PM
intentionally fall back to the platform font.

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
