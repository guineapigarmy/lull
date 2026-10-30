# TestFlight builds from a fork

[`.github/workflows/testflight.yml`](../.github/workflows/testflight.yml) builds the iPhone app from the newest
commit on `main`, signs it with **your** Apple Developer team, uploads it to TestFlight and posts the result in
Slack. Nothing is submitted for App Store review and the Android app isn't built. The upstream App Store and
Google Play workflows stay off, because their `APP_STORE_RELEASE` and `PLAY_STORE_RELEASE` variables are unset.

The app is identified as `com.rohankanjani.lull` (with the App Group `group.com.rohankanjani.lull`), and only the
original developer's team can sign those. The `testflight` lane in
[`fastlane/TestflightFastfile`](../fastlane/TestflightFastfile) swaps them for your own identifiers in the CI
checkout before building, so the code on `main` is never changed. It lives in its own file, with a single `import`
line in the Fastfile, so merging upstream into your fork stays conflict-free.

Each run:

1. Posts **TestFlight build started** in Slack (yellow).
2. Runs the BedJetKit tests, then builds, signs and uploads the app. Build numbers are picked automatically, one
   higher than anything already uploaded for the version.
3. Updates the same Slack message to **Uploaded 1.2 (4) to TestFlight** (green), or **Build failed** or
   **Build cancelled** (red), with a link to the run.

Apple then processes the build (usually 5 to 30 minutes) and TestFlight on your iPhone offers it.

Pushes that only touch Markdown, screenshots, store metadata or `android/` don't start a build. To build without a
new commit, use **Actions → TestFlight → Run workflow**.

## One-time setup

The examples use `com.guineapigarmy.lull` as your bundle identifier. Any reverse-DNS name you control works, as long
as you use the same one everywhere.

### 1. Identifiers

In [Certificates, Identifiers & Profiles → Identifiers](https://developer.apple.com/account/resources/identifiers/list):

1. Click **+**, choose **App Groups**, and register `group.com.guineapigarmy.lull`.
2. Click **+**, choose **App IDs → App**, and register the explicit bundle ID `com.guineapigarmy.lull` with the
   **App Groups** capability ticked. Then open it, click **Configure** next to App Groups, choose the group from
   step 1, and save.
3. Do the same for the widgets: `com.guineapigarmy.lull.widgets`, also with that App Group.
4. Open `com.guineapigarmy.lull` again and tick **Access Wi-Fi Information** too. The app uses it to offer a
   BedJet 3 the network the iPhone is on, and its profile can't be made without it.

When the watch app lands on `main`, add two more the same way: `com.guineapigarmy.lull.watchkitapp` and
`com.guineapigarmy.lull.watchkitapp.widgets`, each with the App Group. The lane signs every target the Fastfile
lists, so the watch app ships inside the next build without other changes.

### 2. The app in App Store Connect

In [App Store Connect → Apps](https://appstoreconnect.apple.com/apps), click **+ → New App**: platform iOS,
bundle ID `com.guineapigarmy.lull`, any SKU (for example `lull`). The name must be unique across the whole App
Store, so "Lull" is taken; use something like "Lull (guineapigarmy)". It's only shown in App Store Connect and
TestFlight. On your Home Screen the app is still called Lull.

Then open the app's **TestFlight** tab, add an **Internal Testing** group, keep **Enable automatic distribution**
on, and add yourself as a tester. Install [TestFlight](https://apps.apple.com/app/testflight/id899247664) on your
iPhone and sign in with the same Apple Account.

### 3. App Store Connect API key

In [Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api),
create a **Team Key** with the **App Manager** role. Note the **Key ID** and **Issuer ID**, and download the
`.p8` file. Apple lets you download it only once.

### 4. Apple Distribution certificate

1. In Xcode, open **Settings → Accounts**, select your team, and click **Manage Certificates**.
2. Click **+** and choose **Apple Distribution**.
3. In **Keychain Access**, find **Apple Distribution: …** under **My Certificates**, right-click it, choose
   **Export**, and save it as `distribution.p12` with a strong password.

### 5. Secrets and variables

These go on `guineapigarmy/lull`. If `gh` has more than one account signed in, switch first:

```bash
gh auth switch -u guineapigarmy
```

From the folder with your files, replacing the placeholders. Each command prompts for or reads the value locally,
so nothing ends up in your shell history:

```bash
gh secret set ASC_KEY_ID --repo guineapigarmy/lull
```

```bash
gh secret set ASC_ISSUER_ID --repo guineapigarmy/lull
```

```bash
gh secret set ASC_KEY_P8 --repo guineapigarmy/lull < AuthKey_XXXXXXXXXX.p8
```

```bash
base64 -i distribution.p12 | gh secret set DIST_CERT_P12_BASE64 --repo guineapigarmy/lull
```

```bash
gh secret set DIST_CERT_PASSWORD --repo guineapigarmy/lull
```

Your Team ID is shown under **Membership details** on [your account page](https://developer.apple.com/account):

```bash
gh variable set TESTFLIGHT_TEAM_ID --body XXXXXXXXXX --repo guineapigarmy/lull
```

Then delete the local `.p12` and keep the `.p8` somewhere safe, such as a password manager.

### 6. Slack

The messages use the same Slack bot and channel as ig, ecobee and stocks, and the same step:
[`.github/actions/slack-status`](../.github/actions/slack-status/action.yml) is a copy of the one in
`guineapigarmy/devops`, since a public repository can't use an action from a private one. The devops bootstrap script
sets the `SLACK_CHANNEL_ID` variable and prompts for the bot's `SLACK_BOT_TOKEN`:

```bash
~/Documents/Git/devops/scripts/bootstrap-repo.sh lull C0C8GBA0WUT
```

Optionally, add a button that opens the app's TestFlight page. The number is the app's **Apple ID**, under
**App Information** in App Store Connect:

```bash
gh variable set APP_URL --body https://appstoreconnect.apple.com/apps/0000000000/testflight/ios --repo guineapigarmy/lull
```

Without Slack settings the build still runs; it just posts nothing.

### 7. Turn it on

Setting the bundle identifier switches the workflow on:

```bash
gh variable set TESTFLIGHT_BUNDLE_ID --body com.guineapigarmy.lull --repo guineapigarmy/lull
```

```bash
gh workflow run testflight.yml --repo guineapigarmy/lull
```

To pause builds, delete the variable.

## Notes

- **Actions minutes.** Builds in a public repository are free. In a private one, macOS runners use the included
  Actions minutes much faster than Linux ones; a run takes a few minutes.
- **Secrets in a public repository.** Only pushes to `main` and manual runs build, and both need write access.
  Pull requests from other forks never see the secrets.
- **Upstream's pull request tests.** `tests.yml` still runs the iOS and Android tests on pull requests in the fork.
  To stop that:

  ```bash
  gh workflow disable tests.yml --repo guineapigarmy/lull
  ```

- **Expiry.** TestFlight builds expire after 90 days. Any push to `main`, or a manual run, uploads a fresh one.
