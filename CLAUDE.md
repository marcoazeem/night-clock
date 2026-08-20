# Night Clock

Flutter nightstand clock that turns a spare Galaxy Note 8 into a bedside
display. Portrait-only (the user moved it to a vertical stand): the hours
stack over the minutes and fill the screen, with a fading white hairline
and the date beneath them and a battery bar at the bottom, on a true-black
background for AMOLED. (It was landscape with the time on one line until
Aug 2026 — don't go back. A month calendar used to sit on the right; the
user removed it as redundant — don't reintroduce it.)

Deliberately minimal — the user has stripped this down twice. One font, two
colours, no icon chrome. Don't add faces, themes, or decoration back.

## Target device

- Samsung Galaxy Note 8 (SM-N950F), Android 9, usually connected over USB.
  adb serial: `ce0617165451ea26057e` — always pass `-s` (a stale offline
  emulator entry often makes bare `adb` fail with "more than one device").
- Phone renders at HD+, so in portrait that's 720×1480 at 280 dpi —
  411×845 logical, devicePixelRatio 1.75. Screenshots come out 720×1480.
- Package is `com.ismail.night_clock` (not `com.example.…`); launch with
  `adb shell am start -n com.ismail.night_clock/.MainActivity`.
- Do NOT inject input (`adb shell input ...`) — the user often holds the
  phone. Verify visuals with golden tests instead (see below). That
  includes `keyevent WAKEUP`: if `dumpsys power` says `mWakefulness=Asleep`
  a screencap is all black, and the fix is to ask the user to wake it.
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

- Portrait layout: `HH` on one line, `MM` under it — no colon. Seconds
  and AM/PM share a small row below the minutes; then the hairline, then
  the date. `digitSize` (`min(w * 1.15, h * 0.55)`) deliberately overshoots
  and the outer `FittedBox` scales the column down to fit, so the digits
  always fill the panel width. Everything under the minutes is held to
  `faceWidth` (`digitSize * 0.83`, the measured width of two DSEG7 digits)
  by `_capWidth` — otherwise a long date sets the width and the digits
  shrink to suit. The battery bar sizes off the panel width, not
  `digitSize`, because `digitSize` is an overshoot.
- One face only: DSEG7 7-segment digits (`_digitFont` and its
  `_digitScale`/`_digitHeight`/`_digitTracking` constants). The font cycle,
  `_FontSpec`, `_ClockStyle`, and the flip/burst/analog faces were all
  deleted — don't bring them back.
- Unlit segments: `_segments()` draws an all-8s layer at `_segmentOff`
  (0.11 of the digit's own opacity) behind every DSEG7 run, so the dark
  segments show the way they do on a real 7-segment panel. It relies on
  DSEG7 being monospaced with "8" driving all seven segments — the layers
  line up with no offset. Keep it; the user asked for it explicitly.
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
- Burn-in protection: whole display wanders ±20×±40 px each minute (the
  reverse of the old landscape values — the panel is now narrow across and
  tall). The face area is inset 24×44 px to match, so drift never pushes
  content offscreen.

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

Two traps that cost real time:

- Never await real file I/O inside `testWidgets` — the fake-async zone
  never pumps it and the test just hangs for the full 10-minute timeout.
  Read the TTF with `readAsBytesSync()` and hand `FontLoader` a
  `Future.value(...)`, or load it in `setUpAll`. Pass `--timeout 60s` so a
  mistake fails fast.
- Ahem is far wider than the real platform font, so never size a layout
  from an Ahem render — the golden shows the date binding the width when
  on-device it doesn't. Measure the DSEG7 digits (which do render for
  real) and cap the other rows to that.

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
