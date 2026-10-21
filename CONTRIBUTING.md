# Contributing to Lull

Thanks for helping. This guide covers how to report problems, set up the project, and get a change
merged.

## Reporting bugs and requesting features

Open an [issue](https://github.com/rkanjani/lull/issues) and include:

- What you did, what you expected, and what happened instead
- Phone model and iOS or Android version, and BedJet firmware version if you know it (`bedjetctl` prints it)
- Whether it happens in Demo mode, on a real BedJet, or both
- Screenshots or a screen recording if the problem is visual

Check existing issues first; a thumbs-up on an existing one is more useful than a duplicate.

Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## One change, both apps

Lull is an iPhone app and an Android app that do exactly the same thing. **A pull request that changes
what Lull does changes both apps**, along with both test suites. You don't need to be fluent in both
Swift and Kotlin: the Android code is a close port, so the twin of any Swift function is usually easy to
find and follow. [AGENTS.md](AGENTS.md) has the rules and a map from each iOS file to its Android twin.
If you can only do one side, open the pull request anyway and say so; it won't be merged until the
other side is done.

## Setting up

1. Fork the repository and clone your fork.

**iPhone**

2. Open `Lull.xcodeproj` in Xcode 16 or later.
3. In **Signing & Capabilities**, pick your own team and change the bundle identifiers of the `Lull`
   and `LullUITests` targets to something unique. Please don't commit these signing changes.
4. Run on the iOS Simulator. It uses the simulated BedJet (`DemoLink`), so you don't need hardware.

**Android**

5. Install JDK 17 and the Android SDK (Android Studio includes both), then open the `android/` folder.
6. Run the **app** configuration on an emulator. Like the iOS Simulator, it uses the simulated BedJet.

## Making a change

1. Create a branch from `main`: `git checkout -b fix-schedule-overlap`.
2. Keep each pull request to one change. Small PRs get reviewed faster.
3. Make the change in both apps (see [AGENTS.md](AGENTS.md) for where each piece lives).
4. Run both apps' tests before pushing:

   ```bash
   cd BedJetKit && swift test
   ```

   ```bash
   cd android && ./gradlew :bedjetkit:test :app:testDebugUnitTest
   ```

   and both UI test suites if you touched an app: Xcode (**Product → Test**) and
   `./gradlew :app:connectedDebugAndroidTest` from `android/` with an emulator running.
5. Add or update tests for what you changed, in both suites:
   - Protocol and encoding changes need a test in `BedJetKit/Tests/BedJetKitTests` and its twin in
     `android/bedjetkit/src/test`.
   - New screens or flows should be covered in `LullUITests` and `android/app/src/androidTest`.
6. Open a pull request against `main` describing what changed, why, and how you tested it on each
   platform. Include before/after screenshots from both apps for UI changes.

Merges to `main` are released to the App Store and Google Play automatically
([docs/RELEASING.md](docs/RELEASING.md)), so leave the version number and `fastlane/` release notes to
the maintainer.

## Code style

- Match the code around you. iPhone: Swift, SwiftUI, `@Observable` models, Swift concurrency with
  `@MainActor`. Android: Kotlin, Jetpack Compose, a `ViewModel` with Compose state, coroutines on the
  main thread. Keep the two ports parallel: same names, same structure, same comments where they fit.
- Prefer small, readable functions and names that say what they do over comments that explain them.
  Use comments for the *why*, such as BedJet quirks.
- No third-party dependencies without discussing it in an issue first.
- No analytics, tracking, accounts, or network calls. Lull is Bluetooth only, and that's a feature.

## Working on the BedJet protocol

`BedJetKit` is the heart of the project, and `android/bedjetkit` is its Kotlin twin:

- `Codec` encodes commands and decodes status bytes.
- `BLELink.swift` and `android/app/.../BleLink.kt` are the Bluetooth transports and the two-phone
  hand-over. The hand-over UUIDs must stay identical so iPhones and Android phones share a BedJet.
- `DemoLink` simulates a BedJet byte for byte. **If you change how the real device is spoken to,
  update `DemoLink` to match on both sides**, so the simulators and tests stay faithful.

When testing against a real BedJet, start with `swift run bedjetctl`, which only reads. Be careful with
anything that writes program slots: it replaces what the owner has saved on their device.

If you discover something new about the protocol, describe how you observed it (firmware version,
captured bytes) in your PR.

## Conduct

Be kind and assume good intent. Harassment or personal attacks aren't tolerated, and maintainers may
remove comments or contributors who don't follow this.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
