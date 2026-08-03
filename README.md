# Night Clock

A bedside nightstand clock (Flutter) for a repurposed Galaxy Note 8 —
landscape like Apple's Nightstand mode, big horizontal time on the left and
the current month's calendar (today highlighted) on the right, on a
true-black AMOLED-friendly background. The screen stays on via
`wakelock_plus`.

## Gestures

- **Tap** — cycle digit colour (red / amber / green / cyan / white)
- **Swipe left / right** — change clock font (Roboto / Doto dot-matrix / DSEG7 7-segment)
- **Swipe up / down** — brighter / dimmer
- **Long-press** — toggle 12/24-hour
- **Double-tap** — show/hide seconds

Settings persist across launches. The whole display wanders within a
±40 × ±20 px region, jumping to a new spot every minute, so no pixel holds a
static image — AMOLED burn-in protection. Battery % and charging state show
at the bottom.

## Fonts

The big digits cycle through three faces:

- **Roboto** — system default
- **Doto** — round dot-matrix in the Nothing phone style (SIL OFL, Google Fonts)
- **DSEG7 Classic** — classic 7-segment digital clock (SIL OFL, by Keshikan)

The bundled fonts and their licenses live in `fonts/`. Nothing's real NDot
font is proprietary, so the OFL-licensed Doto stands in; if you own NDot,
drop its TTF into `fonts/` and point the `Doto` family at it in
`pubspec.yaml`.

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
