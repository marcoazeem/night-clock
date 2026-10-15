# Night Clock

Flutter nightstand clock that turns a spare Galaxy Note 8 into a bedside
display. It stands on a wireless charger and turns both ways up, because
the user lays it on its side once it's full to take it off the coil and
stop it charging all night — so both orientations have to read as a clock.
Both ways up the time is one `HH:MM` line (portrait used to stack HH over
MM; the user flattened it to free room for the lights and AC). Either way a fading white hairline and the date sit under the time
and a battery bar sits at the foot, on a true-black background for AMOLED.
(A month calendar used to sit on the right in landscape; the user removed
it as redundant — don't reintroduce it, in either orientation.)

Since Oct 2026 it's a bedside *dashboard*: the clock plus a panel of the
user's smart lights (see Lights below). The phone now lives on the charger,
so battery saving no longer constrains design. The clock itself stays as
spare as before — one font, two colours; don't add faces or themes back.

## Target device

- Samsung Galaxy Note 8 (SM-N950F), Android 9, usually connected over USB.
  adb serial: `ce0617165451ea26057e` — always pass `-s` (a stale offline
  emulator entry often makes bare `adb` fail with "more than one device").
- Phone renders at HD+, so in portrait that's 720×1480 at 280 dpi —
  411×845 logical, devicePixelRatio 1.75 (landscape: 1480×720 physical,
  845×411 logical). Screenshots come out at the physical size.
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
~/FlutterDev/flutter/bin/flutter build apk --release --split-per-abi --dart-define-from-file=lights.json
adb -s ce0617165451ea26057e install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
adb -s ce0617165451ea26057e push build/app/outputs/flutter-apk/app-arm64-v8a-release.apk /sdcard/Download/night-clock.apk
```

After every install, also refresh the `/sdcard/Download/night-clock.apk`
copy (the user keeps it for reinstalling without the Mac).

Always build with `--dart-define-from-file=lights.json` — without it the
app builds fine but the lights panel silently disappears.

## Architecture (lib/main.dart, plus lib/lights.dart)

- Layout: one `LayoutBuilder` branch on `w > h`. The time is `HH:MM` on
  one line either way; then a small seconds/AM-PM row, the hairline, the
  date. `digitSize` (`min(w * 0.55, h * 1.15)`) deliberately overshoots and the outer `FittedBox` scales the
  column down to fit — `BoxFit.scaleDown` never scales *up*, so an
  undershoot leaves the digits small with no way back. `timeWidth` is the
  time row's real width (`2.902 * digitSize`: DSEG7 advances `0.676` per
  digit and `0.196` for the colon at this tracking — measured with a `TextPainter`,
  not guessed); everything under the time is capped to `faceWidth`
  (`timeWidth * 0.61`) by `_capWidth`, or a long date sets the width and
  the digits shrink to suit.
- Face size is set by the *box*, not by `digitSize` — the `FittedBox`
  refills whatever room it's handed, so scaling `digitSize` does nothing
  at all. The dial is the `_faceScale` (0.8) `FractionallySizedBox` around
  it — the user found a full-bleed face too big. Standing, the width
  factor is 1 so the time spans the panel's width (user asked for a
  bigger clock once the lights sat under it); on its side it's still 0.8.
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
  explicitly rejected a battery-shaped icon and the % readout. It sizes and
  sits off `barSpan` (the panel's *short* side) so it's the same bar in
  both orientations — never off `digitSize`, which is an overshoot. The
  face's bottom padding reserves `barZone` (inset + bolt height + 12) so a
  height-bound landscape face can't grow down into it.
- Two-stage dimmer: `_dim` above `_panelFloor` (0.4) drives real
  window-level brightness (screen_brightness plugin, no permissions,
  system setting untouched, reset on pause/dispose, re-asserted on resume
  and post-first-frame); below it the backlight is at hardware floor and
  `_pixelOpacity` fades pixels down to 0.12.
- Timers still stop when the app is not visible
  (`didChangeAppLifecycleState`) and drift is still an instant jump, but
  battery cost is no longer a reason to reject a feature — the user said the
  phone is always on the wireless charger now.
- Burn-in protection: whole display wanders each minute — ±20×±40 px in
  portrait, ±40×±20 in landscape (wider along the panel's long axis).
  `_drift` holds a unit offset in [-1, 1]² and `build` scales it, so the
  range follows a rotation without the timer knowing the size. The face is
  inset by `drift + 4` on each edge to match, so drift never pushes
  content offscreen.

## Lights (lib/lights.dart, `LightsPanel` in main.dart)

- Local-network only, no cloud. Tapo bulbs over KLAP v2 (HTTP: handshake1/2,
  AES-CBC, signed seq); Mi/Mijia bulbs over miIO (UDP 54321, md5(token)
  key). Mi tries MIoT `set_properties` (siid 2: piid 1 on, piid 2
  brightness) and falls back to legacy `set_power`/`set_bright`.
- The user's two bulbs: the Tapo is "Warm Light", the Mi is "White
  Light"; both dimmable. Each light is a *square* tile, two side by side
  (the user sketched it): name top-left, power circle top-right, a 2×2
  grid of 1 / 25 / 50 / 100% presets at the bottom. No "On"/"Off"/"50%"
  text — the lit power button and preset already say it (the user asked);
  a status line appears only for Offline / Connecting…. The *nearest*
  preset lights up (`_presets`), since a level set in the bulb's own app
  rarely lands exactly on one. (A slider came
  and went — the user replaced it with the presets.) Which lights get
  dimming is `DIMMABLE_LIGHTS` in lights.json, not the brand.
- Dashboard styling: the clock keeps its two colours, but the light tiles
  and AC card are free to use colour and icons (the user asked for it).
  Cards are frosted glass on black — `_glass` / `_glassRaised` /
  `_glassEdge` (white at 5 / 8 / 10%), modelled on a reference the user
  sent, minus its photo background. Each tile glows
  in its light's colour when on — `_glowFor` reads it off the name (cool
  white for "white"/"cool", amber otherwise). Header has an ALL OFF button.
  Panel (header, light squares, then the AC card) sits under the clock in
  portrait and to its right in landscape, laid out at the portrait width
  (`26 * unit`) and shrunk by its FittedBox on its side. One page — no
  swiping. Polls state every 15 s while visible.
- Config is `lights.json` (gitignored; template in lights.example.json),
  passed as dart-defines. The repo is public — never commit IPs or keys.
  `TAPO_HASH` is sha256(sha1(email)+sha1(password)) from
  `tool/tapo_hash.py`, so the APK never holds the Tapo password. Mi tokens
  come from Xiaomi-cloud-tokens-extractor.
- lights.dart has no Flutter imports so it runs under plain `dart` on the
  Mac (`dart run --packages=.dart_tool/package_config.json script.dart`)
  — test protocol changes against the real bulbs or a python-kasa fake.
- The Tapo bulb's HTTP server needs a fixed `Content-Length` (dart:io
  chunks by default) and matches header names case-sensitively — dart:io's
  lowercase `content-length` gets HTTP 400. Headers are set with
  `preserveHeaderCase: true`; keep it. Verified against the real bulb.

## Air conditioner (lib/gree.dart, `AcPanel` in main.dart)

- A Gree unit (Gree+ app) over its LAN protocol: JSON on UDP 7000. Scan for
  the MAC, bind with the shared key to get the unit's own key, then
  status/cmd with that. Old firmware is AES-ECB (`a3K8Bx%2r8Y7#xDh`), new
  is AES-GCM (`{yxAHAY_Lm6pbC/<` — ends in `<`, not `v`; nonce + AAD
  "qualcomm-test"). Bind tries ECB, then GCM. Every pack carries `mac`.
  Replies are GCM-decrypted as CTR without checking the tag, like
  greeclimate. TemSen has a +40 offset. Config is just `GREE_AC=Name=IP`
  — the key comes from the unit at runtime, nothing secret is stored.
- Verified against a fake built on greeclimate's own ciphers (both
  dialects), NOT yet against the user's real unit — its IP wasn't known
  and the user was away from home when this was written (Oct 2026).
- UI: a wide frosted card under the light tiles, same page (it was briefly
  a swipe-away second page; the user wanted everything on one). Compact:
  dial with the setpoint and room temp on the left; title, power switch,
  mode caption and − / + on the right. The user chose power + setpoint
  only — no mode/fan/swing controls. The dial listens to horizontal *and*
  vertical drags so the dimmer swipe doesn't steal it; setpoint changes
  are debounced 0.7 s.

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
committed test. To make the battery bar appear in a golden, mock
`getBatteryLevel` on the `dev.fluttercommunity.plus/battery` method channel
(the charging *stream* is an EventChannel and not worth faking — `barZone`
already reserves the bolt's height whether or not it's charging).

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
