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
- **Swipe up / down** — brighter / dimmer
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
burn-in drift), so nearly all remaining drain is the screen itself being on.
To stretch it: use the red theme at low dim (fewest lit pixels on AMOLED),
set system brightness to minimum, and keep the phone on its charger.

## Build & install

```sh
flutter build apk --release --split-per-abi
adb install -r build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Prebuilt APKs land in `build/app/outputs/flutter-apk/`; the Note 8 wants the
`arm64-v8a` one (`app-release.apk` is the universal fallback).

## Bedside tips

- Keep the phone on a charger; wakelock keeps the screen on indefinitely.
- Turn off adaptive brightness and set system brightness low — then fine-tune
  with the in-app swipe dimmer.
- Samsung "Edge panel" shows a handle on the left edge; disable it in
  Settings → Display → Edge screen for a fully black screen.
