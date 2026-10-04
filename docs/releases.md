# Local installation and fork releases

The `Screendrop` scheme launches Release. `Screendrop Dev` uses Debug Dev with
a separate bundle ID. Install only `/Applications/Screendrop.app` for regular use.

Run `./scripts/build-local-release.sh` to build and certificate-sign locally.
Override `SCREENDROP_SIGNING_IDENTITY` for another identity. The script builds
without installing. It defaults to the same Developer ID identity as releases,
so future local replacements keep the permission identity. Back up the installed
app and quit normally before replacing it. Distribution also requires
notarization through `package-release.sh`. Changing the certificate may
require a new macOS permission grant.

Check the actual installed build and permissions through a normal macOS launch:

```sh
report_dir="$(mktemp -d /tmp/screendrop-diagnostics.XXXXXX)"
open -n -W --stdout "$report_dir/permissions.json" \
  --stderr "$report_dir/permissions.stderr" \
  /Applications/Screendrop.app --args --diagnostics
cat "$report_dir/permissions.json"
```

Use a fresh output file because open can append. Direct executable launches can
inherit Terminal's permission attribution. Add `--request-accessibility` to
request Screendrop's grant. Input Monitoring and Screen Recording are separate
permissions. Builds and diagnostics do not prove every capture/edit interaction.

## Build and release workflows

`.github/workflows/build.yml` builds universal Release on pushes and pull
requests to `helmisatria/Screendrop`. Its unsigned ZIP is for inspection.
Both workflows use macOS 26 runners with Xcode 26.3; the app still targets
macOS 15.6. The macOS 15 runner's asset compiler failed with missing CoreMedia
symbols, so it is not the release build host.

`.github/workflows/release.yml` runs on version tags (`v0.34.1`) or manually from
main with an existing tag. The commit must belong to own main, the tag must match
`MARKETING_VERSION`, and `CURRENT_PROJECT_VERSION` must exceed published builds.
It signs a universal Release with Developer ID, notarizes and staples, generates
a signed ZIP and appcast, verifies the ZIP against the app's embedded public key,
then uploads both assets to a draft release before publishing it as latest.

Published releases cannot be overwritten. Failed drafts can be retried. No
upstream repository or Homebrew tap is modified. The inherited Go release CLI is
disabled. CI is proven only after pushing and observing a successful run.

Configure these repository **variables**:

| Variable | Value |
| --- | --- |
| `APPLE_TEAM_ID` | Your Developer ID certificate's team |
| `DEVELOPER_ID_APPLICATION` | Full `Developer ID Application: NAME (TEAM)` identity |
| `APP_STORE_CONNECT_KEY_ID` | Notarization API key ID |
| `APP_STORE_CONNECT_ISSUER_ID` | Notarization issuer UUID |

Configure these repository **secrets**:

| Secret | Value |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Base64-encoded .p12 containing certificate and private key |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | .p12 export password |
| `APP_STORE_CONNECT_KEY_BASE64` | Base64-encoded notarization .p8 |
| `SPARKLE_PRIVATE_KEY` | Sparkle exported private-key text, without another base64 encoding |

The release job uses a temporary runner keychain and removes credentials
afterward. PR builds receive no signing secrets. Transfer secrets through secure
files/stdin or GitHub's secret UI; never put them in chat, commits, or logs.

Root `AGENTS.md` records local discovery hints. The dedicated Sparkle key is
already in login Keychain under account `helmisatria.Screendrop`. The public key
`GPP/1zhI8AnoKZcO/7C5jIqjOLvxIgDNOvHEXU/+MLE=` is in `Screendrop/Info.plist`.
Preserve this key. Use Sparkle's `generate_keys --account helmisatria.Screendrop
-x PRIVATE_FILE` only for secure backup or transfer to the protected Actions
secret. Do not print the export. Store a secure backup outside the repository.

For local packaging, set `APPLE_TEAM_ID`, `DEVELOPER_ID_APPLICATION`, and either
`SCREENDROP_NOTARY_PROFILE` or the API key/issuer variables above plus
`APP_STORE_CONNECT_KEY_FILE`. Sparkle uses the local Keychain account unless
`SPARKLE_PRIVATE_KEY_FILE` is set. Run:

```sh
./scripts/package-release.sh v0.34.1 /path/outside/repo/release-output
```

Use a fresh output directory. This creates assets without publishing them.
Optional `SCREENDROP_RELEASE_NOTES_FILE` embeds Markdown notes in the appcast.

Once reviewed changes are committed to own main and secrets are configured,
publishing requires explicitly pushing the matching tag to own origin. Never
push to upstream. Branch pushes build artifacts; version tags publish updates.

## Automatic updates

Release uses Sparkle 2.9.1 with the own-repo feed:
`https://github.com/helmisatria/Screendrop/releases/latest/download/appcast.xml`.
The root `appcast.xml` is a legacy placeholder; the release asset is authoritative.

Automatic checks and download/install are enabled by default. Settings > About
lets users disable either option. Sparkle persists their choice and may install
on quit or request macOS authorization where required. Existing preferences
override defaults. No launch code resets them. Until the first signed release
publishes both assets, the feed is unavailable.

The first updater-enabled build must be installed manually because the previous
local app's updater was disabled. Before claiming end-to-end success, publish a
newer build and verify download, signature checking, replacement, relaunch and
permissions from an older installed build.

References: [Sparkle publishing](https://sparkle-project.org/documentation/publishing/),
[automatic updates](https://sparkle-project.org/documentation/customization/), and
[GitHub certificate setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications).

## Optional features

Settings > Features > Captions is enabled by default. Disabling it hides
transcription settings and Studio tools, cancels active transcription, and
removes speech captions from previews and new exports. Saved caption data
remains in the project. Keystroke overlays retain their separate controls.

Render caches record the caption preference so a captioned movie cannot be
reused for an export with captions disabled. Running exports use an immutable
snapshot; toggle changes apply to subsequent exports.

For another feature, extend `ScreendropFeature` with a stable key, title,
description and explicit default, and gate UI/processing with `FeatureSettings`.
Settings lists registered cases automatically. These are local user preferences;
there is no remote rollout service. Deploy code through a normal release.

## Focused checks

```sh
python3 -B scripts/test_release_validation.py
python3 scripts/validate-release.py v0.34.1
bash -n scripts/package-release.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swiftc \
  -parse-as-library Screendrop/FeatureSettings.swift scripts/check-feature-settings.swift \
  -o /tmp/screendrop-feature-checks
/tmp/screendrop-feature-checks
go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.12
```
