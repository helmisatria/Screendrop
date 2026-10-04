# AGENTS.md

## Project overview

Screendrop is a native macOS screenshot and screen recording tool. Its Library window opens on normal launch; login launches remain in the menu bar (`LSUIElement = YES`). `AppActivationPolicy` uses `.regular` while Library, Settings, or editor windows are open, and returns to `.accessory` when they close. Built with SwiftUI + AppKit and no test target.

**Deployment target:** macOS 15.6. Local and CI builds use Xcode 26.3.
**Bundle ID:** `com.fayazahmed.Screendrop`

## Build

Use `xcodebuild` from the command line with the full Xcode toolchain:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build \
  -project Screendrop.xcodeproj \
  -scheme Screendrop \
  -configuration Release \
  -destination "platform=macOS" \
  2>&1 | grep -E "(BUILD SUCCEEDED|BUILD FAILED|error:)" | head -20
```

`Screendrop` launches Release; `Screendrop Dev` launches Debug Dev with a separate
bundle ID. `Screendrop Demo` is also available. Use `Screendrop` for the installed
app. Run `./scripts/build-local-release.sh` for a certificate-signed local Release
build. See `docs/releases.md` for installation, permission checks, and fork CI.

No Xcode test target exists. Build the app and run the focused release-script
checks described in `docs/releases.md` for changes to distribution.

## Signing credentials for this fork

- Repository: `helmisatria/Screendrop`. Never publish to the upstream repository.
- Sparkle's dedicated Ed25519 private key was generated in the local login
  Keychain under account `helmisatria.Screendrop`. Do not generate a replacement
  if this account is available: changing it breaks updates for existing installs.
  Read only its public key with Sparkle's `generate_keys --account
  helmisatria.Screendrop -p`. The matching public key is in
  `Screendrop/Info.plist` (`SUPublicEDKey`). Private keys belong in Keychain or
  GitHub Actions secrets, never in repository files, logs, or chat.
  A protected encrypted backup is
  `/Users/helmisatria/Library/Application Support/Screendrop/Signing/Screendrop-Sparkle-ed25519.key.enc`.
  It uses OpenSSL AES-256-CBC with PBKDF2; its password is the same current
  Keychain export-password item described below. Decrypt only into a protected
  temporary file when recovery is needed; do not regenerate or print the key.
- A candidate certificate export exists locally at
  `/Users/helmisatria/Documents/Helmi Nugraha Dev Profile.p12`. Its certificate
  type and password have not been verified. The new protected Developer ID
  export below is the distribution credential; leave this older file unused.
- On 2026-10-04 a dedicated certificate was issued and imported:
  `Developer ID Application: Helmi Nugraha (WP9CSH76KL)`, team `WP9CSH76KL`,
  certificate ID `A8ANLYR24K`, expires 2031-09-17. Reuse it for distribution.
  Its protected export is
  `/Users/helmisatria/Library/Application Support/Screendrop/Signing/Screendrop-DeveloperIDApplication.p12`.
  The export password is in login Keychain, service
  `screendrop-developer-id-p12-password`, account `helmisatria.Screendrop`.
  Retrieve it only into a variable/stdin for signing or protected secret setup;
  never print it. This Keychain item holds the current password; an initial
  incompatible export was replaced and its temporary password is obsolete.
- `Apple Development: Helmi Nugraha (3GN9W972YM)` remains available for Dev
  builds. Release build scripts use Developer ID; use that identity for
  installed Release replacements to retain macOS grants. Distribution also needs
  notarization. A Sparkle key cannot replace the Apple certificate.
- The candidate `.p12` is password-protected; an empty-password inspection
  failed. On 2026-10-04 the user reconnected the developer team and accepted
  Apple's updated Program License Agreement themselves. Xcode's certificate
  manager initially showed only Apple Development and later disabled creation.
  The new Developer ID was created through Apple's web portal with the user's
  approval. Do not accept legal terms for the user. The team is enrolled as an
  individual; changing the membership name to `Nata` requires Apple's review.
- Recheck `security find-identity -v -p codesigning` before signing. Import the
  user's existing Developer ID certificate or obtain one through their Apple
  developer account; generating a self-signed certificate is insufficient.
- App Store Connect issuer for this team is
  `a4a37a98-8992-45f6-924e-9f5f894ba834`. The old key at
  `/Users/helmisatria/.config/natauang/apple/AuthKey_N5JPHB29M6.p8` returned
  HTTP 401 and was absent from this team's active key lists on 2026-10-04.
  Do not use it for Screendrop notarization. The approved dedicated
  `Screendrop Releases` Developer-role key is `TQLVL63M7P`, stored at
  `/Users/helmisatria/Library/Application Support/Screendrop/Signing/AuthKey_TQLVL63M7P.p8`
  with owner-only permissions. Apple validated it successfully on 2026-10-04.
  Local notarization credentials are in Keychain profile `screendrop-notary`.
- Own-repo Actions already has the Developer ID certificate/password and
  dedicated Sparkle key secrets, plus team/signing-identity variables.
  The validated dedicated notarization key secret and key/issuer variables
  are also configured. Verify secret names with
  `gh secret list --repo helmisatria/Screendrop`; never
  retrieve or print secret values.
- See `docs/releases.md` for the release workflow and credential names. Local
  paths above are discovery hints, not credentials bundled with this checkout.

## Swift concurrency settings

The project uses **strict concurrency** settings that are easy to violate:

- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` - every type is implicitly `@MainActor` unless explicitly opted out.
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` - imports in one file do not leak to other files.

When adding new types, assume `@MainActor` isolation by default. If a type must be `Sendable` or `nonisolated`, mark it explicitly.

## Architecture

All source is in `Screendrop/` (flat, no subdirectories). Key flow:

1. **App entry** - `ScreendropApp.swift`: `@main` App struct. Creates a `MenuBarExtra`, a Settings window, and an annotation editor `WindowGroup`.
2. **Hotkeys** - `HotkeyManager.swift`: Registers global Carbon hotkeys (Option+1/2/3) at launch via `AppDelegate`.
3. **Capture** - `CaptureCoordinator.swift` → `ScreenshotManager.swift`: Fullscreen uses `ScreenCaptureKit`; window/area use `/usr/sbin/screencapture` CLI.
4. **Preview** - `PreviewPanelPresenter.swift` + `PreviewWindowView.swift`: Borderless floating `NSPanel` showing a screenshot stack. Uses `ScreenshotPreviewStack` (an `@Observable` model).
5. **Annotation** - `AnnotationEditorWindow.swift` + `AnnotationEditorModel.swift` + `AnnotationCanvas.swift`: Full annotation editor with tools (rectangle, ellipse, arrow, freehand, text, numbered circles, pixelate, blur). All coordinates are normalized (0..1) relative to the image.
6. **Rendering** - `AnnotationRenderer.swift`: Composites annotations onto the source image at full pixel resolution using Core Graphics.
7. **Preferences** - `ScreendropPreferences.swift` + `SettingsView.swift`: `UserDefaults`-backed settings (auto-save, auto-copy, auto-compress, export directory).
8. **Library** - `CaptureLibraryView.swift` + `CaptureLibraryModel.swift`: Single native sidebar/detail/inspector scene. `CaptureLibraryCollection.swift` reuses AppKit cells for grid/list layouts; `CaptureLibraryThumbnails.swift` bounds decoded image memory and concurrency. The model merges History metadata with recording packages by standardized package path. Existing capture storage and editable sidecars remain authoritative. `CaptureLibraryActions.swift` handles batch operations and prevents trashing captures while their editors are open.

### Singletons

Most managers are `static let shared` singletons: `ScreenshotManager`, `CaptureCoordinator`, `HotkeyManager`, `PreviewPanelPresenter`, `ScreenshotPreviewStack`, `PreviewWindowPlacement`, `PreviewWindowCaptureExclusion`. Follow this pattern for new services.

### Annotation coordinate system

All annotation positions/sizes are normalized to `[0, 1]` relative to the source image dimensions. Pixel conversion happens only in `AnnotationRenderer` at export time and in the canvas view for display. Do not use pixel coordinates in the model layer.

## Conventions

- Apple frameworks provide capture and editing. Sparkle is the pinned SPM
  dependency for updates; preserve `Package.resolved` when building releases.
- **`@Observable` macro** (Observation framework) is used for state - not `ObservableObject`/`@Published`.
- **App sandbox is disabled** (`ENABLE_APP_SANDBOX = NO`) - the app needs screen capture permissions and direct filesystem access.
- Screenshots are saved as lossless PNG to `NSTemporaryDirectory()` first, then optionally compressed to JPEG on export.

## Commits

Make atomic commits. Each commit should represent exactly one logical change (e.g. one feature, one bug fix, one refactor). Do not bundle unrelated changes into a single commit. If a task touches multiple concerns, split it into separate commits. Verify the build passes before committing.

## Entitlements / permissions

- Screen recording permission (`NSScreenCaptureUsageDescription` in Info.plist) is required.
- Hardened runtime is enabled.
- No App Sandbox - do not add sandbox entitlements.
