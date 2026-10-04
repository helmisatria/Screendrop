---
name: release-screendrop
description: "Build, sign, notarize and publish Screendrop releases for the helmisatria/Screendrop fork, including Sparkle updates."
---

# Release Screendrop

Read root `AGENTS.md` and `docs/releases.md`. Publish only to
`helmisatria/Screendrop`. The inherited upstream Go CLI is disabled.
Never use upstream signing credentials, appcast, or Homebrew tap.

1. Inspect git status and preserve unrelated work. Check own latest release.
   Increment `CURRENT_PROJECT_VERSION` for every new version.
2. Check for an installed Developer ID Application certificate and notarization
   credentials using the root hints. Preserve the dedicated Sparkle Keychain
   key `helmisatria.Screendrop`. Never print or commit private credentials.
   Apple Development signing is only for local builds.
3. Run the focused checks in `docs/releases.md` and build Release.
4. Local packaging uses `scripts/package-release.sh TAG OUTPUT_DIRECTORY`
   with documented environment variables. It verifies signing, notarization,
   stapling, architectures and the update signature without publishing.
5. Publishing uses `.github/workflows/release.yml` on version tags. Prepare
   reviewed commits on own main and verify repository variables/secrets.
   Push or publish only when explicitly authorized by the user.
6. Verify Actions and both published ZIP/appcast assets. Test a real update
   from an older installed version, including relaunch and permissions,
   before claiming the updater works end to end.

The app reads the latest GitHub release's appcast asset. Do not edit the root
legacy appcast to announce updates. Published releases cannot be replaced;
failed drafts may be retried.
