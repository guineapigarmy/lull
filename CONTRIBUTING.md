# Contributing to Lull

Thanks for helping. This guide covers how to report problems, set up the project, and get a change
merged.

## Reporting bugs and requesting features

Open an [issue](https://github.com/rkanjani/lull/issues) and include:

- What you did, what you expected, and what happened instead
- iOS version, iPhone model, and BedJet firmware version if you know it (`bedjetctl` prints it)
- Whether it happens in Demo mode, on a real BedJet, or both
- Screenshots or a screen recording if the problem is visual

Check existing issues first; a thumbs-up on an existing one is more useful than a duplicate.

Security problems go through [SECURITY.md](SECURITY.md), not public issues.

## Setting up

1. Fork the repository and clone your fork.
2. Open `Lull.xcodeproj` in Xcode 16 or later.
3. In **Signing & Capabilities**, pick your own team and change the bundle identifiers of the `Lull`,
   `LullWidgets` and `LullUITests` targets to something unique. The app and widgets share an App Group:
   swap it for your own on both targets and in `WidgetSnapshot.appGroup`. Please don't commit these
   signing changes.
4. Run on the iOS Simulator. It uses the simulated BedJet (`DemoLink`), so you don't need hardware.

## Making a change

1. Create a branch from `main`: `git checkout -b fix-schedule-overlap`.
2. Keep each pull request to one change. Small PRs get reviewed faster.
3. Run the tests before pushing:

   ```bash
   cd BedJetKit && swift test
   ```

   and the UI tests from Xcode (**Product → Test**) if you touched the app.
4. Add or update tests for what you changed:
   - Protocol and encoding changes need a test in `BedJetKit/Tests/BedJetKitTests`.
   - New screens or flows should be covered in `LullUITests`.
5. Open a pull request against `main` describing what changed, why, and how you tested it. Include
   before/after screenshots for UI changes.

Merges to `main` are submitted to the App Store automatically ([docs/RELEASING.md](docs/RELEASING.md)),
so leave the version number and `fastlane/` release notes to the maintainer.

## Code style

- Match the code around you: Swift, SwiftUI, `@Observable` models, Swift concurrency with `@MainActor`.
- Prefer small, readable functions and names that say what they do over comments that explain them.
  Use comments for the *why*, such as BedJet quirks.
- No third-party dependencies without discussing it in an issue first.
- No analytics, tracking, accounts, or network calls. Lull is Bluetooth only, and that's a feature.

## Working on the BedJet protocol

`BedJetKit` is the heart of the project:

- `Codec.swift` encodes commands and decodes status bytes.
- `BLELink.swift` is the CoreBluetooth transport and the two-phone hand-over.
- `DemoLink.swift` simulates a BedJet byte for byte. **If you change how the real device is spoken to,
  update `DemoLink` to match**, so the Simulator and tests stay faithful.

When testing against a real BedJet, start with `swift run bedjetctl`, which only reads. Be careful with
anything that writes program slots: it replaces what the owner has saved on their device.

If you discover something new about the protocol, describe how you observed it (firmware version,
captured bytes) in your PR.

## Conduct

Be kind and assume good intent. Harassment or personal attacks aren't tolerated, and maintainers may
remove comments or contributors who don't follow this.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
