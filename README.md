# Lull

Schedule your BedJet 3 through the night. No account, no cloud.

![Lull screens](screens.png)

Lull is an iOS app that plans a whole night of heating and cooling for a BedJet 3, saves it to the
BedJet itself, and lets the BedJet run it. Your phone can sleep, leave the room, or run out of battery;
the night keeps going.

- **Schedules**: build a night out of phases (Cool, Heat, Gentle heat, Turbo, Dry, Pause), each with
  its own temperature, fan speed and duration, and see the whole curve at a glance.
- **Runs on the device**: tonight's schedule is written into one of the BedJet's three program slots.
- **Remote**: a direct remote for mode, temperature, fan and shut-off timer.
- **Two phones, one BedJet**: the BedJet only accepts one connection, so Lull hands it over between
  phones automatically.
- **Private**: Bluetooth only. No accounts, analytics, or network calls.

> Lull is an independent project and is not affiliated with or endorsed by BedJet LLC.

## Repository layout

| Path | What it is |
| --- | --- |
| `Lull/` | The SwiftUI app (model, schedules, views, theme) |
| `BedJetKit/` | Swift package: the BedJet 3 Bluetooth protocol, a CoreBluetooth transport, and a simulated BedJet |
| `BedJetKit/Sources/bedjetctl` | A read-only command-line tool that prints a real BedJet's status and saved programs |
| `LullUITests/` | UI tests that walk the main flows against the simulated BedJet |
| `screenshots/`, `app-store-screenshots/` | Marketing and App Store screenshots |

## Getting started

Requirements: Xcode 16 or later, iOS 18 or later for the app. BedJetKit also builds on macOS 14.

```bash
git clone https://github.com/rkanjani/lull.git
cd lull
open Lull.xcodeproj
```

In Xcode, select the **Lull** target, open **Signing & Capabilities**, choose your own team, and change
the bundle identifier to something unique (for example `com.yourname.lull`). Then run.

**No BedJet? No problem.** The iOS Simulator has no Bluetooth, so the app uses a simulated BedJet
(`DemoLink`) that speaks the same bytes as the real one. You can also turn on Demo mode on a device.

### Running tests

```bash
# Protocol and codec tests
cd BedJetKit && swift test
```

UI tests run from Xcode (**Product → Test**) or with:

```bash
xcodebuild test -project Lull.xcodeproj -scheme Lull -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

### Talking to a real BedJet from your Mac

```bash
cd BedJetKit && swift run bedjetctl
```

`bedjetctl` connects to the first BedJet it finds, prints its status, name, firmware and saved
programs, then exits. It changes nothing on the device.

## Contributing

Contributions are welcome: bug reports, protocol findings, fixes and features. Read
[CONTRIBUTING.md](CONTRIBUTING.md) for how to set up, the code style, and how to open a pull request.

To report a security issue, see [SECURITY.md](SECURITY.md) rather than opening a public issue.

## License

[MIT](LICENSE)
