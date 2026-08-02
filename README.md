# Night Clock

A bedside nightstand clock (Flutter) for a repurposed Galaxy Note 8 —
landscape like Apple's Nightstand mode, big horizontal time on the left and
the current month's calendar (today highlighted) on the right, on a
true-black AMOLED-friendly background. The screen stays on via
`wakelock_plus`.

## Gestures

- **Tap** — cycle digit colour (red / amber / green / cyan / white)
- **Swipe up / down** — brighter / dimmer
- **Long-press** — toggle 12/24-hour
- **Double-tap** — show/hide seconds

Settings persist across launches. The clock drifts a few pixels every minute
to protect the AMOLED panel from burn-in. Battery % and charging state show
at the bottom.

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
