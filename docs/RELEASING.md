# Releasing to the App Store

Every push to `main` that changes the app runs [`.github/workflows/app-store.yml`](../.github/workflows/app-store.yml).
It tests BedJetKit, builds and signs the app, uploads it to App Store Connect, and submits it for review.
Once Apple approves it, it's released automatically.

What a push does depends on the version in Xcode (`MARKETING_VERSION`, shown as **Version** on the
Lull target's General tab):

| State of that version on App Store Connect | What the workflow does |
| --- | --- |
| Already live on the App Store | Nothing. Raise the version to release. |
| New, or being prepared | Uploads a build and submits it for review. |
| Waiting for review or in review | Pulls that submission, then submits the newer build. **This puts you back in the review queue.** |

Build numbers are picked automatically: one higher than anything already uploaded for that version.
Docs-only changes (Markdown files and screenshots) don't trigger a release.

## Cutting a release

1. Raise **Version** (for example 1.0 → 1.1).
2. Write what's new in [`fastlane/metadata/en-US/release_notes.txt`](../fastlane/metadata/en-US/release_notes.txt).
3. Merge to `main`, then watch the **App Store release** run in the Actions tab.

## One-time setup

The workflow stays off until the steps below are done.

### 1. App Store Connect API key

In [App Store Connect → Users and Access → Integrations → App Store Connect API](https://appstoreconnect.apple.com/access/integrations/api),
create a **Team Key** with the **App Manager** role. Note the **Key ID** and **Issuer ID**, and download
the `.p8` file. Apple lets you download it only once.

### 2. Apple Distribution certificate

The workflow signs with an Apple Distribution certificate exported as a `.p12` file:

1. In Xcode, open **Settings → Accounts**, select your team, and click **Manage Certificates**.
2. Click **+** and choose **Apple Distribution**. Skip this if one already shows without "(cloud managed)".
3. In **Keychain Access**, find **Apple Distribution: …** under **My Certificates**, right-click it,
   choose **Export**, and save it as `distribution.p12` with a strong password.

### 3. Secrets

The secrets live in the repository's `app-store` environment, which only `main` can use. Run these from
the folder with your files, replacing the placeholders. Each command prompts for or reads the value
locally, so nothing ends up in your shell history:

```bash
gh secret set ASC_KEY_ID --env app-store --repo rkanjani/lull
```

```bash
gh secret set ASC_ISSUER_ID --env app-store --repo rkanjani/lull
```

```bash
gh secret set ASC_KEY_P8 --env app-store --repo rkanjani/lull < AuthKey_XXXXXXXXXX.p8
```

```bash
base64 -i distribution.p12 | gh secret set DIST_CERT_P12_BASE64 --env app-store --repo rkanjani/lull
```

```bash
gh secret set DIST_CERT_PASSWORD --env app-store --repo rkanjani/lull
```

Then delete the local `.p12` and keep the `.p8` somewhere safe, such as a password manager.

### 4. Turn it on

```bash
gh variable set APP_STORE_RELEASE --body true --repo rkanjani/lull
```

To run it right away without a new commit, use **Actions → App Store release → Run workflow**, or:

```bash
gh workflow run app-store.yml --repo rkanjani/lull
```

To pause releases, set the variable to `false`.

## Security notes

- Secrets are scoped to the `app-store` environment, and only the `main` branch can deploy to it, so
  workflows from forks and pull requests never see them.
- The API key can manage apps but not users or payments. Revoke it in App Store Connect if it leaks.
- Third-party actions are pinned to commit SHAs. Review the changes before bumping them.
