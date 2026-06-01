# Source-Only Release Preparation — Design

**Date:** 2026-06-01
**Status:** Approved for planning
**Topic:** Prepare Tom's Fans for a source-only GitHub release

## Goal

Make the project build and install cleanly from a fresh `git clone` on any user's
Mac, with the privileged fan-control helper installable two ways: the in-app
SMAppService button (primary) and a `sudo` script (reliable fallback).

The GitHub "release" ships **tagged source**, not a signed binary. Every user
builds locally, so there is no Gatekeeper/quarantine or notarization concern, and
ad-hoc signing is kept on purpose.

## Distribution decisions (settled during brainstorming)

- **Channel:** Source-only GitHub release. Users clone and build locally.
- **Signing:** Ad-hoc (`CODE_SIGN_IDENTITY = "-"`, `DEVELOPMENT_TEAM = ""`) kept
  deliberately so a cloner with no Apple Developer account can build and run.
- **Install paths:** In-app SMAppService button (primary) + `sudo ./install-helper.sh`
  (fallback). Both must work for a locally-built app.

### Explicitly out of scope (YAGNI for source-only local builds)

- Developer ID signing, notarization, stapling.
- Entitlements files and app sandboxing.
- Hardening the XPC client requirement beyond identifier-only. The existing
  `identifier "com.tomsfans.app"` check in `Helper/FanControlDelegate.swift` is
  adequate for a locally-built personal app (its own code comment says so).

## Background: why the current state doesn't work for release

- The app installs the helper via `SMAppService.daemon(plistName:)`
  (`App/Services/HelperInstallService.swift`), but `Helper/launchd.plist` uses the
  legacy `ProgramArguments` → `/Library/PrivilegedHelperTools/com.tomsfans.helper`
  layout. SMAppService daemons must reference the executable **inside the app
  bundle** via the `BundleProgram` key (Apple: executable in `Contents/Resources/`,
  plist in `Contents/Library/LaunchDaemons/`). With the absolute path, a clean
  install registers the daemon but launchd has nothing to exec.
- The "Embed Helper Tool" build phase copies the helper binary into **both**
  `Contents/Resources/` (correct, what `BundleProgram` will point at) and
  `Contents/Library/LaunchDaemons/` (unnecessary — only the plist belongs there).
- `Tom's Fans.xcodeproj/xcshareddata/` (the shared "Tom's Fans" scheme) is
  **untracked in git**. Without it, `xcodebuild -scheme "Tom's Fans"` fails on a
  fresh clone — nobody could build.
- `install-helper.sh` locates the helper via `-scheme "com.tomsfans.helper"`, which
  is not a shared scheme and won't exist on a clean clone.
- `install-helper.sh` defaults to the **Debug** build configuration.
- README still references `SMJobBless` and "Download the latest release" (binary),
  neither of which matches the code or the source-only plan.

## Design

### 1. `Helper/launchd.plist` — SMAppService (BundleProgram) layout

Replace the `ProgramArguments` + absolute path with `BundleProgram` pointing at the
in-bundle executable, and associate it with the app:

- `Label` = `com.tomsfans.helper`
- `BundleProgram` = `Contents/Resources/com.tomsfans.helper`
- `MachServices` = `{ com.tomsfans.helper = true }`
- `KeepAlive` = `true`
- `AssociatedBundleIdentifiers` = `[ com.tomsfans.app ]` (clean association/display
  in System Settings › General › Login Items & Extensions)

This plist is the one embedded in the app bundle and named by
`SMAppService.daemon(plistName: "com.tomsfans.helper.plist")`.

### 2. `Helper/launchd-system.plist` — new, for the sudo script

The `sudo` script installs a **system** LaunchDaemon, which has no bundle context,
so it needs the legacy absolute-path layout (mutually exclusive with `BundleProgram`):

- `Label` = `com.tomsfans.helper`
- `ProgramArguments` = `[ /Library/PrivilegedHelperTools/com.tomsfans.helper ]`
- `MachServices` = `{ com.tomsfans.helper = true }`
- `KeepAlive` = `true`

### 3. "Embed Helper Tool" build phase

Stop copying the helper binary into `Contents/Library/LaunchDaemons/`. Keep copying
the plist there, and keep the existing Resources copy phase that places the
executable at `Contents/Resources/com.tomsfans.helper` (where `BundleProgram`
points). Net result in the built bundle:

- `Contents/Resources/com.tomsfans.helper` (executable)
- `Contents/Library/LaunchDaemons/com.tomsfans.helper.plist` (BundleProgram plist)

### 4. `install-helper.sh` — clean-clone portable, Release by default

- Query `BUILT_PRODUCTS_DIR` from the **app** scheme (`-scheme "Tom's Fans"`),
  not the unshared `com.tomsfans.helper` scheme. The app target builds the helper as
  a dependency, so the helper binary lands in the same products directory.
- Default to `-configuration Release` (was Debug).
- Install `Helper/launchd-system.plist` (absolute-path layout) to
  `/Library/LaunchDaemons/com.tomsfans.helper.plist` — **not** the bundle plist.
- Keep the already-applied fixes: run `xcodebuild` as `$SUDO_USER`, resolve the real
  user's `$HOME`/DerivedData, and the apostrophe-safe `find -print0 | xargs -0`
  fallback (the repo path contains `Tom's`).

### 5. `build-release.sh` — new, one-command build for cloners

- `xcodebuild -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" -configuration Release build`
- Print the resulting `.app` path on success.
- No distributable-artifact/zip step — the release is tagged source.

### 6. Commit the shared scheme

Add `Tom's Fans.xcodeproj/xcshareddata/` (the shared "Tom's Fans" scheme) to git so
`xcodebuild -scheme "Tom's Fans"` resolves on a fresh clone.

### 7. README / documentation (primary deliverable)

- Replace `SMJobBless` references with `SMAppService`.
- Replace "Download the latest release" binary language with build-from-source.
- Add: requirements (macOS 13+, Xcode), `git clone` → `./build-release.sh` (or open
  in Xcode), note that the app is unsigned/ad-hoc and builds locally with no Apple
  account.
- Document both install paths, including that the in-app button may report
  **"Requires Approval"** — enable once in System Settings › General › Login Items &
  Extensions. `HelperInstallService` already surfaces this status.
- Document uninstall (`sudo ./uninstall-helper.sh`).

### 8. Minor UI hint (optional, low-risk)

When `HelperInstallService.status == .requiresApproval`, surface a hint pointing the
user to System Settings. The status string already exists; this is a small UI touch.

## Components & responsibilities

| Unit | Responsibility | Depends on |
|------|----------------|------------|
| `Helper/launchd.plist` | Describe the daemon for SMAppService (in-bundle) | `BundleProgram` path matching the Embed phase |
| `Helper/launchd-system.plist` | Describe the daemon for the system install (script) | binary at `/Library/PrivilegedHelperTools/` |
| "Embed Helper Tool" phase | Place executable in Resources, plist in LaunchDaemons | helper build product |
| `install-helper.sh` | Locate Release helper, install system daemon | app scheme, `launchd-system.plist` |
| `build-release.sh` | Build the Release `.app` | shared "Tom's Fans" scheme |
| README | Tell users how to build + install | all of the above |

## Error handling

- `install-helper.sh`: clear error when no Release build is found (build first);
  apostrophe-safe path handling; runs `xcodebuild` as the invoking user under `sudo`.
- `HelperInstallService`: already surfaces `.requiresApproval` and `lastError`; the
  UI hint guides the user to System Settings when approval is needed.
- SMAppService with ad-hoc signing on the build machine can still require manual
  approval; the `sudo` script is the documented fallback.

## Testing / acceptance

1. Fresh clone builds: `git clone` → `./build-release.sh` produces `Tom's Fans.app`.
2. Shared scheme present: `xcodebuild -scheme "Tom's Fans"` resolves without
   auto-creating a scheme.
3. Bundle layout: built app has the executable in `Contents/Resources/` and the
   `BundleProgram` plist in `Contents/Library/LaunchDaemons/`, and **no** binary in
   `Contents/Library/LaunchDaemons/`.
4. Script install: `sudo ./install-helper.sh` finds the Release helper, installs the
   system daemon; `launchctl print system/com.tomsfans.helper` shows it loaded; fan
   control works from the app.
5. In-app button: launching the Release `.app` and clicking install reaches
   "Enabled" (after System Settings approval if prompted); fan control works.
6. Uninstall: `sudo ./uninstall-helper.sh` unloads and removes the binary and plist.
7. README steps are copy-pasteable and match actual behavior.
