# Night Clock

Flutter nightstand clock that turns a spare Galaxy Note 8 into a bedside
display. It stands on a wireless charger and turns both ways up, because
the user lays it on its side once it's full to take it off the coil and
stop it charging all night — so both orientations have to read as a clock.
Both ways up the time is one `HH:MM` line (portrait used to stack HH over
MM; the user flattened it to free room for the lights and AC). Either way a fading white hairline and the date sit under the time, on a
true-black background for AMOLED. (There's no battery bar any more — the
phone is always on the charger, so the user had it removed along with
battery_plus. Don't bring it back.)
(A month calendar used to sit on the right in landscape; the user removed
it as redundant — don't reintroduce it, in either orientation.)

Since Oct 2026 it's a bedside *dashboard*: the clock plus a panel of the
user's smart lights, ACs and TV. The phone now lives on the charger, so
battery saving no longer constrains design. On 19 Oct 2026 the user asked
for a "major" modern redesign — colour, a background, glass — see Look
below. The old rule "one font, two colours, spare" no longer holds.

## Target device

- Samsung Galaxy Note 8 (SM-N950F), Android 9, usually connected over USB.
  adb serial: `ce0617165451ea26057e` — always pass `-s` (a stale offline
  emulator entry often makes bare `adb` fail with "more than one device").
- Phone renders at HD+, so in portrait that's 720×1480 at 280 dpi —
  411×845 logical, devicePixelRatio 1.75 (landscape: 1480×720 physical,
  845×411 logical). Screenshots come out at the physical size.
- Package is `com.ismail.night_clock` (not `com.example.…`); launch with
  `adb shell am start -n com.ismail.night_clock/.MainActivity`.
- Screen is failing (Oct 2026): a dark patch top-right and a purple line
  (the S8/Note 8 hardware fault — not fixable in software). Heat speeds it
  up, so fast wireless charging was turned off at the user's request
  (`settings put global wireless_fast_charging 0`). The phone can't stop
  charging at 100% itself (Android 9 has no Protect battery; no root); a
  Tapo smart plug driven by the app was offered as the way to do it.
- Do NOT inject input (`adb shell input ...`) — the user often holds the
  phone. Verify visuals with golden tests instead (see below). That
  includes `keyevent WAKEUP`: if `dumpsys power` says `mWakefulness=Asleep`
  a screencap is all black, and the fix is to ask the user to wake it.

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

Over Wi-Fi: Android 9 has no wireless pairing, so with the phone on USB
run `adb -s <serial> tcpip 5555`, then `adb connect <phone-ip>:5555`
(IP from `adb shell ip -f inet addr show wlan0`) and use `-s
<phone-ip>:5555` in place of the serial. It lasts until the phone
reboots; after that it needs the cable once more.

After every install, also refresh the `/sdcard/Download/night-clock.apk`
copy (the user keeps it for reinstalling without the Mac).

Always build with `--dart-define-from-file=lights.json` — without it the
app builds fine but the lights panel silently disappears.

## Architecture (lib/main.dart, plus lib/lights.dart)

- Layout: one `LayoutBuilder` branch on `w > h`. The time is `HH:MM` on
  one line either way, always 24-hour with no seconds (the user removed
  the 12h/AM-PM and seconds options and their gestures); then the
  hairline and the date, with the weather card beside the lot. `digitSize` (`min(w * 0.55,
  h * 1.15)`) deliberately overshoots and the outer `FittedBox` scales the
  column down to fit — `BoxFit.scaleDown` never scales *up*, so an
  undershoot leaves the digits small with no way back. Each glyph sits in
  a fixed slot (`_digitSlot` 0.52, `_colonSlot` 0.312 × font size,
  measured with a `TextPainter`; Nabla's "1" is narrower even with tabular
  figures), so `timeWidth` is `digitSize * (4 * 0.52 + 0.312)` and the
  clock doesn't resize as the minutes change. The hairline is capped to
  `faceWidth` (`timeWidth * 0.61`), and so is the date.
- Face size is set by the *box*, not by `digitSize` — the `FittedBox`
  refills whatever room it's handed, so scaling `digitSize` does nothing
  at all. The dial is the `_faceScale` (0.8) `FractionallySizedBox` around
  it — the user found a full-bleed face too big. Standing it's 0.82 wide ×
  1.0 tall: full width ran the last digit into a dark patch at the top
  right of this phone's OLED (the user can't see that corner), so keep
  the top-right clear. On its side it's still 0.8 × 0.8.
- Clock font: **Nabla** (Google Fonts, a COLRv1 colour font — the user
  chose it), so the digits carry their own colours and ignore text colour.
  The user picked palettes on nabla.typearture.com: **0** (yellow-orange)
  by day, **3** (slate) at night. Flutter can't select a font palette, so
  `fonts/Nabla-Night.ttf` is Nabla with palette 3 copied into slot 0
  (fontTools, CPAL) — family `NablaNight`. Flutter renders COLRv1 fine on
  the Note 8 (checked on device). DSEG7, its unlit-segment layer and the
  red "1"s went with the switch. Nabla covers A–Z, digits and · too.
- Everything else is **Inter** (bundled, 300–700), set app-wide as the
  theme font. The date is Nabla too (same day/night palette as the time,
  `dateStyle`) — in red Inter it looked out of place beside the 3D digits
  (the user said so).
- Gestures: vertical swipe = dim, and that's all — long-press 12/24h and
  double-tap seconds were removed at the user's request. The dim level
  persists via SharedPreferences. The 8-second hint says "swipe up / down
  to dim".
- Two-stage dimmer: `_dim` above `_panelFloor` (0.4) drives real
  window-level brightness (screen_brightness plugin, no permissions,
  system setting untouched, reset on pause/dispose, re-asserted on resume
  and post-first-frame); below it the backlight is at hardware floor and
  `_pixelOpacity` fades pixels down to 0.12.
- Timers still stop when the app is not visible
  (`didChangeAppLifecycleState`) and drift is still an instant jump, but
  battery cost is no longer a reason to reject a feature — the user said the
  phone is always on the wireless charger now.
- Burn-in protection: the clock and panel wander each minute — ±8×±12 px
  in portrait, ±12×±8 in landscape — gliding there over 20 s
  (TweenAnimationBuilder) instead of jumping. It was ±20×±40 jumps on a
  static black screen; the user found that too much once the sky started
  moving, and the moving sky covers most of the screen anyway.
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
  Light"; both dimmable. Each light is a *square* tile, two side by side.
  Restyled 24 Oct 2026 from a mock-up the user sent: the top is one big
  power button (the whole button toggles) holding a bulb icon in a rounded
  square, a round power badge top-right, then the name and a state line
  ("Warm Glow · 50%", "Off · Icy White", Offline / Connecting…). On, the
  button is filled with the light's colour (gradient towards orange) with
  dark ink; off, faint glass. This replaced the earlier icon-only button
  that filled left-to-right with the brightness — the user had asked to
  remove the name and text then, and asked for them back with this look.
  The 1 / 25 / 50 / 100% presets sit under it as one segmented pill. The *nearest*
  preset lights up (`_presets`), since a level set in the bulb's own app
  rarely lands exactly on one. (A slider came
  and went — the user replaced it with the presets.) Which lights get
  dimming is `DIMMABLE_LIGHTS` in lights.json, not the brand.
- Dashboard styling: see Look below. Header (same mock-up): the home icon
  in a rounded square, ROOM DASHBOARD (renamed from LIGHTS) with "Master
  Bedroom" under it (the user named the room), and two scene pills — GN
  deep navy with a lavender moon, GM a glowing amber gradient — that replaced ALL OFF
  (`_runScene`): **GN** — White Light off, Warm Light on at 1%, Bedroom AC
  on at 24°; **GM** — Bedroom AC off, Warm Light 100%, White Light on.
  Lights are found by "white"/"warm" in their names, the AC by name
  "Bedroom". Steps run in parallel; afterwards `_acNudge` makes the AC
  tiles re-read their units at once.
  Panel (header, light squares, then the AC tiles) sits under the clock in
  portrait and to its right in landscape, laid out at the portrait width
  (`26 * unit`) either way. One page, no swiping — but the panel scrolls
  vertically once it outgrows its room (the user said scrolling is fine
  when they added a second AC), though the user wants the current set
  (2 lights, 2 ACs, TV) to fit unscrolled. Standing, its max height leaves
  the clock `0.4 * width`; today everything fits with room to spare.
  (The weather shows just icon + temperature — the user had the low – high
  range removed, on both apps.)
  A status line closes the panel (`_statusLine`, from a second mock-up):
  green Wi-Fi "Connected · Home Wi-Fi" (red "No devices answering" if no
  light or AC answers — the SSID needs location permission on Android, so
  it isn't read), and "All systems nominal" with a shield, or "<name>
  offline" / "N devices offline". AcPanel reports offline via `onOffline`. Polls state every 15 s while visible.
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
- If the Tapo bulb answers `handshake1` with **HTTP 403** (even to a bare
  request), it's refusing local apps: Tapo app → Me → Third-Party
  Services → **Third-Party Compatibility** must be on. A firmware update
  turned it off once (Oct 2026); switching it on fixed it at once.

## Rooms (Oct 2026: from bedside dashboard to whole-home dashboard)

- `ROOMS` in lights.json splits the devices into rooms: `"Name (Subtitle)=
  device,device; Other Room="`, devices by their config names. The user's
  house: **Haam's Room** (Haam's AC — the third Gree unit — Haam's TV, the
  TCL Android TV, and a Tapo bulb still to add), **M&M's Room** (Master
  Bedroom: Warm/White Light, Bedroom + AC 2 ACs, the Hisense "TV"),
  **Sitting Room** (Beyond TV), **Kitchen** (nothing yet). Without ROOMS
  it's one room and no home page, as before.
- `HomePanel` (home page): a 2×2 grid of room cards (icon by name — bed /
  sofa / kitchen — name, subtitle or "2 lights · 1 AC", "Here" on this
  device's room). Tap a card → that room's `LightsPanel`; the header's
  house tile goes back home. Each device opens on `START_ROOM` (phone: in
  lights.json, M&M's Room; iPad: build.sh sets M&M's Room too — Haam's iPad sits there) and returns
  there after 2 min untouched (`_idleReturn`). The home page ends in the same status line (`_StatusBar` /
  `NCStatusLine`), Wi-Fi read from the device itself every 30 s ("No
  Wi-Fi" in red when off), "All systems nominal" on the right. Only the room on screen
  polls. GN/GM appear only in a room holding their devices (`_hasScenes`).
- Locked rooms: `ROOM_PINS` in lights.json (`"Room=1234"`; the
  code stays out of the public repos). Opening one from the home page shows
  a passcode pad in the panel's place (`PinPad` / `NCPinView`): dots and a
  keypad, red flash on a wrong code, house icon to cancel. A device's own
  room never asks; the 2-min idle walk back closes the pad.
- The home page has its own background clip, `homescreen.mp4` (a forest),
  at any hour and in any weather — dimmed after dark; on the iPad a still
  after dark, like the others.
- TV card: a Hisense on its own gets the wide button; an Android TV on its
  own (Haam's TCL) gets the wide button plus volume over ADB
  (`KEYCODE_VOLUME_*`). Android TVs without a MAC try `KEYCODE_WAKEUP` to
  turn on (a TCL keeps ADB up in standby); only if that fails does it say
  "Use the remote to turn on".
- iPad: the same in Panel.m (`NCRoom`, `NCConfiguredRooms`, `NCHomeView`,
  `NCPanelView initWithRoom:`) and ClockViewController (`showRoom:`,
  `NCTouchView` for the idle timer).

## Air conditioner (lib/gree.dart, `AcPanel` in main.dart)

- A Gree unit (Gree+ app) over its LAN protocol: JSON on UDP 7000. Scan for
  the MAC, bind with the shared key to get the unit's own key, then
  status/cmd with that. Old firmware is AES-ECB (`a3K8Bx%2r8Y7#xDh`), new
  is AES-GCM (`{yxAHAY_Lm6pbC/<` — ends in `<`, not `v`; nonce + AAD
  "qualcomm-test"). Bind tries ECB, then GCM. Every pack carries `mac`.
  Replies are GCM-decrypted as CTR without checking the tag, like
  greeclimate. TemSen has a +40 offset. The user's units don't beep
  for Wi-Fi commands: `Buzzer_ON_OFF` 0 and 1 were both tried with real
  setpoint changes (Oct 2026) and stayed silent, and status keeps reporting
  1 whatever is sent — so commands don't carry it. Don't retry. Config is just `GREE_AC=Name=IP`
  — the key comes from the unit at runtime, nothing secret is stored.
- Verified against the user's real unit (Oct 2026): it reports firmware
  V3.4.M but answers the bind only in **GCM** (the ECB bind times out, then
  GCM succeeds — that's why the first call, scan + bind, takes ~4 s); scan
  replies are ECB. The house has three Gree units; the dashboard shows two,
  "Bedroom" then "AC 2", one card each (`GREE_AC` is comma-separated,
  `LightsPanel.acs`). Gree+ shows only the MAC, not the IP — find IPs by
  broadcasting `{"t":"scan"}` to UDP 7000 on the subnet and decrypting the
  replies with the generic ECB key.
- UI: one tile per AC, two side by side under the light squares, same
  width as a light tile but 1.3× as tall so the dial has room (it was a
  wide card per AC, then the user wanted both visible at once). Name and
  mode top-left, the lights' power circle top-right (in the AC's yellow
  accent), dial with the setpoint in the middle, − / room temp / + along
  the foot. The user chose power + setpoint
  only — no mode/fan/swing controls. The dial listens to horizontal *and*
  vertical drags so the dimmer swipe doesn't steal it; setpoint changes
  are debounced 0.7 s.

## TV (lib/tv.dart, `_tvCard` in main.dart)

- The user's Hisense TV runs VIDAA. Its remote (the RemoteNOW app's) is an
  MQTT broker on the TV, port 36669, TLS with Hisense's self-signed
  "RemoteCA" cert, login `hisenseservice` / `multimqttservice` (no client
  cert on this firmware). tv.dart hand-rolls the few MQTT 3.1.1 packets it
  needs (CONNECT, PUBLISH QoS 0, DISCONNECT) — no package.
- Paired once (Oct 2026) with client id `nightclock` (`tvClientId`): the TV
  showed a 4-digit code, sent as `{"authNum":"…"}` to
  `/remoteapp/tv/ui_service/nightclock/actions/authenticationcode`.
  Pairing is per client id — change it and the TV asks for a new code.
- Keys go to `/remoteapp/tv/remote_service/nightclock/actions/sendkey`
  (payload `KEY_POWER`, `KEY_VOLUMEUP`, …). NOT the `…/nightclock$normal/…`
  form some guides give — this firmware ignores that one silently.
- State: the broker only listens while the TV is on, so a TCP connect to
  36669 *is* the on/off reading (it closes ~6 s after KEY_POWER). On is
  Wake-on-LAN to the TV's MAC (its Wake on LAN / Wireless settings are
  enabled); it comes up in ~4–6 s. The panel ignores polls for 20 s after
  a tap (`_tvSettle`) so the slow broker doesn't flip the button back.
- Config `HISENSE_TV=Name=IP/MAC`. Off → on → off verified on the real TV.
- UI: a wide card under the AC tiles — a big power button (TV + power
  icons, `_tvBlue` when on) and volume − / + squares, live only when on.
  It was briefly a chip in the header; the user wanted it below, with
  volume, and the panel scrolling.

## Beyond TV box (lib/adb.dart, `AndroidTvBox` in lib/tv.dart)

- The user's Medianet "Beyond TV" is an Android TV box on the living-room
  TCL (IP in lights.json's BEYOND_TV; its Cast name says "Bedroom TV" —
  ignore that). NOT the other Android TV box on the network ("Living
  Room TV", runs the user's own streamit app) — it was mistaken for the
  Beyond box once and given a debugging approval; leave it alone.
- Controlled over network ADB (port 5555): lib/adb.dart is a minimal
  hand-written ADB client (CNXN/AUTH/OPEN/WRTE, RSA PKCS#1 signing with
  BigInt, adbd's public-key format — byte-identical to adb's own). The
  phone makes its own key once (`_loadAdbKey`, SharedPreferences
  'adbKey'); the box shows "Allow USB debugging?" the first time and the
  user accepts on the TV. State: `dumpsys power` mWakefulness; off:
  `input keyevent KEYCODE_SLEEP` (works). Asleep, the box drops off the
  network (port 5555 closes), so unreachable reads as Off and it can't be
  woken over ADB. On needs Wake-on-LAN to its MAC (`BEYOND_TV=Name=IP/MAC`,
  untested whether this box supports it); without a MAC, tapping On says
  "Use the remote to turn on". The user is fine with off-only for now. One command at a time
  per box so a waiting approval prompt isn't stacked.
- Config `BEYOND_TV=Name=IP`. UI (the user's layout): in the TV card, the
  box's big power button first (`_boxBlue`), then the Hisense TV's small
  square power button, then the volume pill (volume goes to the Hisense).
- Don't press keys on these boxes from the Mac without saying so — the
  user noticed and asked what was going on.

## Look (Oct 2026 redesign)

- Times of day (the user proposed night 20–06 / morning 06–12 /
  afternoon 12–15 / evening 15–20, then chose to keep these): stars from
  19:00 (`_isDark`), red night mode + slate clock 23:00–06:00
  (`_isNight`), morning sun 06–11, sunset glow 17–19, blue sky between.
- Background `_Backdrop`, by time and weather: after dark near-black with
  twinkling stars, two-thirds of them in the top third around the clock
  (the user asked for stars there); morning a sunrise wash with
  `_SunPainter` up-left of the clock; day deep blue with a smaller sun;
  evening violet into a sunset glow; raining (day)
  slate with falling rain; raining at night, faint rain and no stars.
  The sun and anything bright stay off the top-right (dead OLED patch).
  The moving layer is `_Sky`/`_SkyPainter`: one painter driven by a
  ticker throttled to ~30 fps (paused by Flutter when the app is hidden),
  repainting in its own RepaintBoundary without rebuilds. Per scene: night
  — panning twinkling stars, a shooting star every 23 s, drifting nebula
  glows; rain — rolling clouds, three depths of rain, splashes, a lightning
  flash every 41 s (faint at night); morning/day — sun with breathing haze
  and slowly turning short rays, drifting clouds, rising motes; evening —
  pink clouds and motes. (Green parallax mountains along the foot were
  tried and removed — the user said the green looked bad; don't re-add.)
  Clouds are puff clusters drawn in a saveLayer each, kept
  in the top third — big ones over the cards washed the buttons out. The
  user asked for "live wallpaper" skies made in code (not video). Still costs GPU (the glass cards re-blur each frame) —
  measure heat on the phone before adding more.
- **Background videos** (`_VideoSky`, video_player): the user's own clips
  play behind everything — sunny by day (mornings too; the user dropped
  the morning clip, Oct 2026), night (after
  dark), rainy (whenever it rains — after dark too, under a very dark
  wash; the user wants a video at all times, not the drawn rain). Originals sit in the repo root, shrunk by
  ffmpeg to `assets/video/<name>.mp4` (1280×720, 15 fps, H.264 baseline,
  CRF 26, no audio). All gitignored (`/*.mp4`, `/*.mov`,
  `/assets/video/*.mp4`) — likely stock footage, public repo; a fresh
  clone falls back to the drawn sky. Muted, looping, mixWithOthers (never
  pauses music), paused when the app is hidden, under a dark wash
  (heavier in night mode). To change a clip: drop it in the root, re-run
  the same ffmpeg line into assets/video.
- **Power, measured on USB (Oct 2026)**: drawn sky animating at 20 fps
  cost ~200–400 mA — the battery stalled on slow wireless charging. Now the
  drawn sky updates every 2 s (`SKY_FRAME_MS`, ≈ frozen), the burn-in
  drift is a plain jump again (a 20 s glide cost frames), and a video
  costs ~30–130 mA. Measure with `current_now` on USB, interleaving a
  baseline (`FREEZE_SKY`, `NO_VIDEO` dart-defines) — charge current tapers
  as the level rises, so back-to-back numbers drift.
- Cards are frosted glass (`_GlowCard`: BackdropFilter blur 22, a wash of
  the device's hue, `_EdgePainter` gradient border, glow when on).
- Each device keeps its colour on or off: Warm Light amber, White Light
  icy white, TV violet, AC by mode (cool cyan, heat orange, fan green, dry
  blue, auto teal). The AC dial runs cyan → mint → yellow → orange
  (`_dialStops`; straight cyan→orange went grey in the middle). A light's
  power button fills left-to-right with its brightness; presets are one
  segmented pill with a sliding highlight. The TV card names the input
  (`HisenseTv.source()`, "HDMI 1").
- Night mode (23:00–06:00): `_hue()` pulls every device colour 80% to
  `_nightRed`.
- Weather (lib/weather.dart): Open-Meteo, no key, every 15 min — the only
  internet call. `WEATHER_AT=lat,lon` in lights.json (Malé; the user is in
  the Maldives). Only rain vs not: WMO code ≥ 51 or precipitation > 0.1.
  Shown right of the clock (`_weatherCard`, layout from a wall-panel photo
  the user sent) with no card behind it — the user had the frosted tile
  removed. Its temperature and range are Nabla too, like the time and date
  (the user asked for the whole top to match); the icon is Material: sun (06–18) / moon / cloud with drops,
  the temp now, and today's low ~ high (Open-Meteo daily min/max). On its
  side the card goes under the clock. Its right edge keeps the clock's
  old margin, clear of the dead top-right patch.
- Preview other times with dart-defines `FORCE_NIGHT`, `FORCE_MORNING`,
  `FORCE_RAIN`, `FORCE_CLEAR` (ignores live rain) (=true). Always reinstall a plain build afterwards — the
  user once saw a forced-morning sun at night mid-test.
- The pre-redesign code and APK are in the session scratchpad only;
  git history (4cfabcc) has the last committed pre-redesign state.

## Fonts (fonts/)

Nabla.ttf + Nabla-Night.ttf (see above) with OFL-Nabla.txt; Inter
Light/Regular/Medium/SemiBold/Bold with OFL-Inter.txt. DSEG7 was removed
when the user switched the clock to Nabla.

## Verifying visuals without the phone

Write a throwaway golden test, run
`flutter test --update-goldens test/<name>.dart`, Read the PNG, then
delete the test and `test/goldens/`. Notes: the test font (Ahem) renders
text as solid boxes (geometry is still checkable; load real TTFs via
FontLoader when glyphs matter).

Two traps that cost real time:

- Never await real file I/O inside `testWidgets` — the fake-async zone
  never pumps it and the test just hangs for the full 10-minute timeout.
  Read the TTF with `readAsBytesSync()` and hand `FontLoader` a
  `Future.value(...)`, or load it in `setUpAll`. Pass `--timeout 60s` so a
  mistake fails fast.
- Ahem is far wider than the real platform font, so never size a layout
  from an Ahem render — the golden shows the date binding the width when
  on-device it doesn't. Measure the Nabla digits (which do render for
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

## iPad version (ipad/) — the old iPad "Haam"

The user also runs the dashboard on an iPad 4th gen ("Haam", iPad3,6,
iOS 10.3.4, 32-bit armv7, UDID in gitignored `ipad/.udid`).
Flutter and Swift can't target it, so `ipad/` is a hand-written
Objective-C/UIKit port: clock + weather + videos (FaceView, SkyView), the
lights / ACs / TV / Beyond box panel (Panel.m), and the protocols
(Devices.m: Tapo KLAP, Mi miIO, Gree; TV.m: Hisense MQTT-over-TLS via
Secure Transport, ADB with a keychain RSA key, Wake-on-LAN). Changes to
the Flutter app's look or behaviour don't carry over automatically — port
them by hand when the user wants both.
- `ipad/` is its own public git repo, github.com/marcoazeem/night-clock-ipad,
  nested here and gitignored by this one — commit iPad changes from inside
  `ipad/`. Same rule: no IPs or keys (the UDID lives in gitignored
  `ipad/.udid`).

- Build + install: `ipad/build.sh install` — over USB, or over Wi-Fi
  when unplugged (Wi-Fi sync is on; other tools take `-n` then, e.g.
  `idevicedebug -n --detach run …`, `idevicescreenshot -n`) (reads lights.json;
  `FORCE_NIGHT=1` etc. work as env vars). Output in `ipad/build/`
  (gitignored — it holds Config.h with the keys).
- Nabla can't render on iOS 10 (COLRv1), so `ipad/tool/glyphs_test.dart`
  renders every character and Material icon to PNGs via `flutter test`;
  the app draws those. Add an icon there when the panel needs a new one.
- Toolchain tricks (all in build.sh): the iOS 10.3 SDK from theos/sdks in
  `~/Library/Developer/LegacySDKs`, patched by `ipad/tool/fix_sdk.py`
  (simulator archs out of the .tbd stubs, armv7 objc_msgSend_stret in);
  `-marm` (Thumb entry point → SIGILL at launch); `-fno-objc-exceptions`
  (no SjLj unwinder in the SDK — so no `@try`); armv7 math helpers linked
  from Xcode's `libclang_rt.cc_kext_ios.a`.
- Signing: team D88J248KNQ (seastack) wildcard dev profile, which lists
  Haam; bundle id `mv.seastack.nightclock`. Install with `ideviceinstaller`
  (Xcode can't see iOS 10 devices).
- Screenshots and launching: mount the iOS 10.3 DeveloperDiskImage
  (`ideviceimagemounter`, from a community archive) once per iPad boot,
  then `idevicescreenshot` and `idevicedebug --detach run
  mv.seastack.nightclock`. Screenshots come out portrait (rotate them).
- The iPad has its own ADB key (keychain), so the Beyond box asked for
  approval once for it too.
