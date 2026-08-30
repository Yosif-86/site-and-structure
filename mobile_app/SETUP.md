# Setting up the app (Yosif runs this)

I couldn't run Flutter in the session that wrote this code (not installed on that
machine), so the `lib/` source exists but the native `android/`/`ios/` project
folders and `pubspec.lock` don't yet — Flutter needs to generate those itself,
matched to whatever Flutter version you install.

## 1. Install Flutter
Follow https://docs.flutter.dev/get-started/install/windows for Windows.
Also install Android Studio (for the Android SDK + an emulator) if you don't
have it. Run `flutter doctor` afterward and fix anything it flags red.

## 2. Generate the native scaffolding
From this `mobile_app/` folder:
```bash
flutter create --org com.siteandstructure --project-name site_and_structure .
```
This fills in `android/`, `ios/`, and `pubspec.lock` around the existing
`lib/` and `pubspec.yaml` — say yes if it asks to overwrite `pubspec.yaml`
only if it warns about conflicts; otherwise it should merge cleanly since
`lib/` and `pubspec.yaml` already exist and `flutter create` won't touch them.

## 3. Install packages
```bash
flutter pub get
```

## 4. Native permission tweaks
**Android** — `android/app/src/main/AndroidManifest.xml`, inside `<manifest>`
(above `<application>`), make sure this is present (usually added by default):
```xml
<uses-permission android:name="android.permission.INTERNET" />
```

**iOS** — `ios/Runner/Info.plist`, add (needed for `image_picker`'s gallery access
when uploading a payment screenshot):
```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>Used to attach a screenshot of your payment.</string>
```

## 5. Run it
```bash
flutter run
```
Pick an emulator/device when prompted. If something doesn't compile, that's
expected on a first pass I couldn't test locally — send me the exact error
and I'll fix it.

## iOS builds
This machine can't compile iOS apps (Apple requires Xcode on macOS). Once the
app runs on Android, we'll set up a Codemagic pipeline to build the iOS version
in the cloud — ping me when you're ready for that step.
