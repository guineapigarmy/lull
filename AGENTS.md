# Working on Lull

Lull ships as two native apps from this one repository: an iPhone app (Swift, SwiftUI) and an Android
app (Kotlin, Jetpack Compose, in `android/`). **They are one product.** Anyone changing either app,
person or agent, follows the rules below.

## The parity rule

Every change to what Lull does lands in both apps in the same pull request: features, fixes,
protocol findings, copy, limits, defaults and tests. A change made only to one app is unfinished.

- **Same behaviour.** Same screens, flows, controls, limits, defaults, timings and error handling.
  The Android app is a line-by-line port: when you change a Swift function, change its Kotlin twin
  (see the map below), keeping the same names, structure and comments where the languages allow.
- **Same words.** User-facing text is identical, except where the platform differs (for example
  "Control Center" on iOS is "Quick Settings" on Android, and "iPhone" becomes "phone").
- **Same bytes.** Anything that touches the BedJet changes `Codec`, the `Link` helpers and `DemoLink`
  on both sides, with the same test added to both test suites. Hand-over UUIDs must stay identical so
  iPhones and Android phones keep passing a BedJet to each other (`handOverRequestMatchesTheIPhoneApp`
  pins this).
- **Same tests.** A test added to one suite gets its twin in the other (table below).
- **Same version.** Both apps read `MARKETING_VERSION` from `Lull.xcodeproj`. Release notes go in
  both `fastlane/metadata/en-US/release_notes.txt` and `fastlane/metadata/android/en-US/changelogs/default.txt`.
- **Platform-only work** (signing, permissions, Info.plist, the Android manifest, store plumbing) is
  fine on one side. Say so in the pull request.
- If something truly can't be matched, say why in the pull request and add it to "Known differences" below.

## Where each piece lives

| What | iPhone | Android |
| --- | --- | --- |
| Protocol types and limits | `BedJetKit/Sources/BedJetKit/Models.swift` | `android/bedjetkit/src/main/kotlin/com/rohankanjani/lull/bedjetkit/Models.kt` |
| Byte encoding | `BedJetKit/.../Codec.swift` | `android/bedjetkit/.../Codec.kt` |
| Link protocol and helpers | `BedJetKit/.../Link.swift` | `android/bedjetkit/.../Link.kt` |
| Simulated BedJet | `BedJetKit/.../DemoLink.swift` | `android/bedjetkit/.../DemoLink.kt` |
| Bluetooth transport | `BedJetKit/.../BLELink.swift` | `android/app/src/main/java/com/rohankanjani/lull/BleLink.kt` |
| Hand-over UUID | `BLELink.handoffUUID` | `android/bedjetkit/.../Handoff.kt` |
| App state and actions | `Lull/AppModel.swift` | `android/app/.../AppModel.kt` |
| Schedules, phases, templates, formatting | `Lull/Schedule.swift` | `android/app/.../Schedule.kt` |
| Colours and shared controls | `Lull/Theme.swift` | `android/app/.../ui/Theme.kt` |
| Tabs, alerts, screen scaffold | `Lull/Views/RootView.swift` | `android/app/.../ui/RootScreen.kt` |
| Remote tab | `Lull/Views/RemoteView.swift` | `android/app/.../ui/RemoteScreen.kt` |
| Schedule tab | `Lull/Views/ScheduleView.swift` | `android/app/.../ui/ScheduleScreen.kt` |
| Schedule and phase editors | `Lull/Views/ScheduleEditor.swift` | `android/app/.../ui/ScheduleEditor.kt` (`TemperatureSlider` is in `RemoteScreen.kt`, `ModePicker` in `Theme.kt`) |
| Night curve | `Lull/Views/NightCurve.swift` | `android/app/.../ui/NightCurve.kt` |
| BedJet sheet | `Lull/Views/DeviceSheet.swift` | `android/app/.../ui/DeviceSheet.kt` |
| Launch and lifecycle | `Lull/LullApp.swift` | `android/app/.../MainActivity.kt` |
| Protocol tests | `BedJetKit/Tests/BedJetKitTests/CodecTests.swift` | `android/bedjetkit/src/test/.../CodecTest.kt` |
| App logic tests | | `android/app/src/test/.../ScheduleTest.kt` |
| UI tests | `LullUITests/LullUITests.swift` | `android/app/src/androidTest/.../LullUiTest.kt` |
| Store screenshots | `LullUITests/StoreScreenshots.swift` | `android/app/src/androidTest/.../StoreScreenshots.kt` |
| Store listing | `fastlane/metadata/en-US/` | `fastlane/metadata/android/en-US/` |
| Release | `fastlane ios release`, `.github/workflows/app-store.yml` | `fastlane android release`, `.github/workflows/play-store.yml` |

Launch flags match too: `-ephemeral`, `-demoElapsedMinutes`, `-demoLabelConnected` and `-logConnections`
on iOS are the `ephemeral`, `demoElapsedMinutes`, `demoLabelConnected` and `logConnections` intent extras on Android.

## Checking a change

Run both before opening a pull request. The **Tests** workflow runs the unit tests on every pull request.

```bash
cd BedJetKit && swift test
xcodebuild test -project Lull.xcodeproj -scheme Lull -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

```bash
cd android && ./gradlew :bedjetkit:test :app:testDebugUnitTest
cd android && ./gradlew :app:connectedDebugAndroidTest   # needs an emulator or phone
```

Both simulators run against the simulated BedJet, so no hardware is needed. For UI changes, compare
the two apps side by side: the screens should look like the same app.

## Known differences

Platform conventions, not behaviour:

- Android uses Material components where iOS uses system ones (bottom navigation bar, bottom sheets,
  the time picker, the long-press menu), styled to match Lull's look.
- Android asks for the "Nearby devices" permission when Lull first needs Bluetooth; iOS asks for Bluetooth.
- On Android, if a quick connection to the remembered BedJet times out (usually because another phone
  has it), Lull waits for it in the background, which is what iOS does from the start.
- Google Play skips a release whose version is already on the production track, but unlike the App
  Store lane it doesn't replace a release that is still in review.

## Style

Match the code around you, in either language. Small readable functions, names that say what they do,
comments for the *why* (BedJet quirks, platform workarounds). No third-party dependencies beyond the
ones each app already has without discussing it first. No analytics, tracking, accounts or network calls.
