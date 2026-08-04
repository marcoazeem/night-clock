# Night Clock

A bedside nightstand clock (Flutter) for a repurposed Galaxy Note 8 —
landscape like Apple's Nightstand mode, big horizontal time on the left and
the current month's calendar (today highlighted) on the right, on a
true-black AMOLED-friendly background. The screen stays on via
`wakelock_plus`.

## Gestures

- **Tap** — cycle digit colour (red / amber / green / cyan / white)
- **Swipe left / right** — cycle clock styles: 9 fonts plus 3 fun faces
  (flip clock, dash burst, analog)
- **Swipe up / down** — brighter / dimmer (two-stage, see Battery)
- **Long-press** — toggle 12/24-hour
- **Double-tap** — show/hide seconds

Settings persist across launches. The whole display wanders within a
±40 × ±20 px region, jumping to a new spot every minute, so no pixel holds a
static image — AMOLED burn-in protection. Battery % and charging state show
at the bottom.

## Fonts

Swiping cycles through nine fonts:

- **Roboto** — system default
- **NDot 47** — "inspired by Nothing" community dot-matrix font
- **Doto** — round dot-matrix in the same style (SIL OFL, Google Fonts)
- **DSEG7 Classic** — classic 7-segment digital clock (SIL OFL, by Keshikan)
- **Orbitron** — geometric sci-fi (SIL OFL, Google Fonts)
- **Oxanium** — squared tech face (SIL OFL, Google Fonts)
- **Nabla** — 3D colour font; paints its own colours, so the theme tint
  doesn't apply (SIL OFL, Google Fonts)
- **Bitcount Ink** — pixel dot-matrix (SIL OFL, Google Fonts)
- **Saira Condensed** — tall condensed sans (SIL OFL, Google Fonts)

…then three fun faces:

- **Flip clock** — split-flap cards that fold down on each minute change
- **Dash burst** — stacked digits ringed by radiating dashes, date on top
- **Analog** — minimal face with radial ticks, 12/3/6/9 numerals, and the
  date beside the centre

The bundled fonts and their licenses live in `fonts/`. NDot 47 is a fan
recreation distributed for free; the OFL fonts include their license texts.

## Battery

With seconds hidden the app redraws about twice per minute (minute change +
burn-in drift), and it runs no background work at all — no services, no
background permissions, and both timers stop when the app isn't visible. So
nearly all drain is the screen itself being on.

The dimmer therefore drives the panel, not just the pixels. Swiping runs a
two-stage control:

- **Top 60% of the range** — sets the app window's own screen brightness,
  from the panel's hardware floor up to full. This is the part that saves
  power, and it needs no `WRITE_SETTINGS` permission; the system brightness
  you set elsewhere is left alone and restored when the app backgrounds.
- **Bottom 40%** — the panel is already at its floor, so this fades the
  pixels toward black (down to 12% opacity). It's the only way to go dimmer
  than the hardware allows, and on AMOLED darker pixels still draw less.

To stretch it further: use the red theme (fewest lit subpixels on AMOLED),
and keep the phone on its charger — a screen-on Note 8 pulls ~1.5–2.5 W, so
a 5 W trickle charger will lose that race. Use an Adaptive Fast Charging
brick.

To cut everything else on the phone, see **Bedside tips** below.

## Build & install

```sh
flutter build apk --release --split-per-abi
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Prebuilt APKs land in `build/app/outputs/flutter-apk/`; the Note 8 wants the
`arm64-v8a` one (`app-release.apk` is the universal fallback).

## Bedside tips

- Keep the phone on a charger; wakelock keeps the screen on indefinitely.
- Brightness is handled in-app now — just swipe. Turn off adaptive brightness
  (Settings → Display) so the system doesn't fight the app.
- Samsung "Edge panel" shows a handle on the left edge; disable it in
  Settings → Display → Edge screen for a fully black screen.

### Cutting background drain (Note 8, Android 9 / One UI 1.0)

The app itself does nothing in the background, so anything left is the rest
of the phone:

- **Airplane mode on.** A cellular radio hunting for signal in a nightstand
  corner is the single biggest drain. Re-enable Wi-Fi separately if wanted.
- Bluetooth, NFC, Location, Mobile data, Hotspot — off.
- Settings → Accounts and backup → Accounts → **Auto sync data** off.
- Device care → Battery → ⋮ → Settings → turn on *Put unused apps to sleep*
  and *Auto disable unused apps*.
- **Add Night Clock to "Apps that won't be put to sleep"**, or Samsung's
  optimiser will kill it overnight. Also set it to *Not optimised* under
  Settings → Apps → ⋮ → Special access → Optimise battery usage.
- Play Store → Settings → Auto-update apps → *Don't auto-update*.
- Disable Bixby Home / Voice / Routines, and Always On Display (redundant
  with this app, and it lights pixels).
- Settings → Display → Screen mode → **Basic** draws less than Vivid.
- For a fully dedicated device: remove the Google account entirely, which
  stops most Play Services wakeups.
