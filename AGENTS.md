# Repository Guidelines

## Project Structure & Module Organization

Night Clock is a Flutter bedside clock and local smart-home dashboard targeting Android. `lib/main.dart` contains the app, clock, room dashboard, and visual effects. Device protocols live in `lights.dart`, `gree.dart`, `tv.dart`, and `adb.dart`; weather and energy estimates live in `weather.dart` and `energy.dart`.

`test/` contains Flutter tests. `android/` holds the native host and Gradle configuration. Images belong in `assets/images/`, optional videos in `assets/video/`, and bundled fonts and licenses in `fonts/`. `tool/tapo_hash.py` generates Tapo authentication hashes. If present, `ipad/` is a separate, gitignored repository; manage its changes independently.

## Build, Test, and Development Commands

Use Flutter with Dart compatible with `^3.12.2`.

- `flutter pub get`: install dependencies.
- `flutter run`: launch the clock on a connected device.
- `flutter run --dart-define-from-file=lights.json`: launch with local device configuration.
- `dart format lib test`: format Dart source and tests.
- `flutter analyze`: run static analysis and configured Flutter lints.
- `flutter test`: run the test suite.
- `flutter build apk --release --split-per-abi --dart-define-from-file=lights.json`: build release APKs in `build/app/outputs/flutter-apk/`. Omit the define flag for an unconfigured clock.

## Coding Style & Naming Conventions

Follow Dart formatter output with two-space indentation. Use `snake_case.dart` filenames, `UpperCamelCase` types, `lowerCamelCase` members, and leading underscores for library-private declarations. Follow `flutter_lints` from `analysis_options.yaml`. Keep protocol logic separate from widgets, and preserve lifecycle handling that pauses timers and playback when hidden.

## Testing Guidelines

Use `flutter_test` and name tests `*_test.dart`. The existing widget smoke test mocks SharedPreferences and pumps past the hint timer; follow that pattern for timer-dependent widgets. Add focused coverage for changed behavior; no numerical coverage threshold is configured. Check visual changes in portrait, landscape, and night mode. Mock device communication rather than controlling household devices during automated tests.

## Commit & Pull Request Guidelines

Recent commits use short, imperative subjects such as “Add an electricity estimate card to the home page.” Keep commits focused. PRs should describe behavior changes, record validation, link relevant issues, and include screenshots for visual changes. Push only when explicitly requested.

## Security & Configuration

Copy `lights.example.json` to gitignored `lights.json` for local setup. Never commit real addresses, tokens, hashes, bills, or private apartment imagery. Configuration secrets are compiled into APKs; treat configured builds as private. Preserve bundled asset licenses.
