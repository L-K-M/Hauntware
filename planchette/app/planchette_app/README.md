# Planchette app

Run `flutter pub get`, `flutter test`, then `flutter run -d macos`
(or `linux` / `windows`). The reusable editor lives in `packages/planchette_editor`.

Android: run `flutter build apk --release`, or `../../scripts/build.sh android`
to stage `dist/planchette-android.apk`. Native provider tests run with
`./gradlew :app:testDebugUnitTest` from `android/` after a Flutter build.
