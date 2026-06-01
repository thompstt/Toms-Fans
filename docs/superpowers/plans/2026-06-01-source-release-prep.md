# Source-Only Release Preparation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Tom's Fans build and install cleanly from a fresh `git clone`, with the privileged helper installable via both the in-app SMAppService button and a `sudo` script.

**Architecture:** Fix the embedded launchd plist to the SMAppService `BundleProgram` layout, add a separate absolute-path plist for the system (script) install, make the helper-install script clean-clone portable and Release-default, add a one-command build script, commit the shared Xcode scheme, and promote build-from-source docs to the README. Signing stays ad-hoc on purpose (no Apple account needed to build).

**Tech Stack:** Xcode project (pbxproj), launchd property lists, ServiceManagement (`SMAppService`), SwiftUI/AppKit, Bash.

**Reference spec:** `docs/superpowers/specs/2026-06-01-source-release-prep-design.md`

**Working branch:** `source-release-prep` (already created).

> **Note on "tests":** This is build-configuration, plist, shell, and docs work — there are no unit tests to write. Each task uses concrete verification commands (build, inspect the bundle, `plutil`, `launchctl`) as its pass/fail check. Run them and confirm the stated expected output before committing.

---

### Task 1: Commit the shared Xcode scheme (unblocks clean-clone builds)

The shared scheme `Tom's Fans.xcodeproj/xcshareddata/` is currently untracked. Without it, `xcodebuild -scheme "Tom's Fans"` fails on a fresh clone.

**Files:**
- Add to git: `Tom's Fans.xcodeproj/xcshareddata/`

- [ ] **Step 1: Verify the shared scheme exists on disk**

Run: `ls "Tom's Fans.xcodeproj/xcshareddata/xcschemes/"`
Expected: `Tom's Fans.xcscheme`

- [ ] **Step 2: Confirm the scheme resolves via xcodebuild**

Run: `xcodebuild -project "Tom's Fans.xcodeproj" -list`
Expected: the Schemes list includes `Tom's Fans`.

- [ ] **Step 3: Stage and commit the shared scheme**

```bash
git add "Tom's Fans.xcodeproj/xcshareddata"
git commit -m "Commit shared Tom's Fans scheme for clean-clone builds"
```

---

### Task 2: Rewrite `Helper/launchd.plist` to the SMAppService BundleProgram layout

This plist is embedded in the app bundle and named by `SMAppService.daemon(plistName: "com.tomsfans.helper.plist")`. It must reference the in-bundle executable via `BundleProgram`, not an absolute path.

**Files:**
- Modify: `Helper/launchd.plist`

- [ ] **Step 1: Replace the entire file contents**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tomsfans.helper</string>
    <key>BundleProgram</key>
    <string>Contents/Resources/com.tomsfans.helper</string>
    <key>MachServices</key>
    <dict>
        <key>com.tomsfans.helper</key>
        <true/>
    </dict>
    <key>AssociatedBundleIdentifiers</key>
    <array>
        <string>com.tomsfans.app</string>
    </array>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 2: Validate the plist**

Run: `plutil -lint Helper/launchd.plist`
Expected: `Helper/launchd.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add Helper/launchd.plist
git commit -m "Switch embedded helper plist to SMAppService BundleProgram layout"
```

---

### Task 3: Create `Helper/launchd-system.plist` for the sudo script

The system LaunchDaemon installed by the script has no bundle context, so it uses the legacy absolute-path layout. This is a new, separate file.

**Files:**
- Create: `Helper/launchd-system.plist`

- [ ] **Step 1: Create the file**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.tomsfans.helper</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Library/PrivilegedHelperTools/com.tomsfans.helper</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>com.tomsfans.helper</key>
        <true/>
    </dict>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

- [ ] **Step 2: Validate the plist**

Run: `plutil -lint Helper/launchd-system.plist`
Expected: `Helper/launchd-system.plist: OK`

- [ ] **Step 3: Commit**

```bash
git add Helper/launchd-system.plist
git commit -m "Add absolute-path launchd plist for sudo script install"
```

---

### Task 4: Stop the Embed phase from copying the binary into LaunchDaemons

The "Embed Helper Tool" run-script phase currently copies the helper binary into **both** `Contents/Resources/` (via a separate Resources copy phase — keep that) and `Contents/Library/LaunchDaemons/` (remove that). Only the plist belongs in `LaunchDaemons/`.

**Files:**
- Modify: `Tom's Fans.xcodeproj/project.pbxproj` (the `shellScript` of the "Embed Helper Tool" phase, around line 385)

- [ ] **Step 1: Replace the shellScript string**

Use the Edit tool to replace this exact substring:

```
\nmkdir -p \"${HELPER_DST}\"\ncp -f \"${HELPER_SRC}\" \"${HELPER_DST}/com.tomsfans.helper\"\ncp -f \"${PLIST_SRC}\" \"${HELPER_DST}/com.tomsfans.helper.plist\"\n
```

with:

```
\nmkdir -p \"${HELPER_DST}\"\ncp -f \"${PLIST_SRC}\" \"${HELPER_DST}/com.tomsfans.helper.plist\"\n
```

(This removes only the line that copies the binary into `LaunchDaemons/`. The now-unused `HELPER_SRC` variable definition can stay — it is harmless — or be removed in the same edit if preferred.)

- [ ] **Step 2: Verify the project file still parses**

Run: `plutil -lint "Tom's Fans.xcodeproj/project.pbxproj"`
Expected: `OK` (pbxproj is a valid old-style plist; `plutil` accepts it).

- [ ] **Step 3: Verify the build still configures**

Run: `xcodebuild -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" -showBuildSettings >/dev/null && echo OK`
Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add "Tom's Fans.xcodeproj/project.pbxproj"
git commit -m "Embed phase: stop double-copying helper binary into LaunchDaemons"
```

---

### Task 5: Add `build-release.sh`

One-command Release build for cloners. Ad-hoc signed; no Apple account needed.

**Files:**
- Create: `build-release.sh`

- [ ] **Step 1: Create the script**

```bash
#!/bin/bash
# build-release.sh — Build Tom's Fans in Release configuration.
# Usage: ./build-release.sh
#
# Produces an ad-hoc-signed app bundle for local use. No Apple Developer
# account or signing identity is required.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building Tom's Fans (Release)…"
xcodebuild -project "$SCRIPT_DIR/Tom's Fans.xcodeproj" \
    -scheme "Tom's Fans" \
    -configuration Release \
    build

APP_DIR=$(xcodebuild -project "$SCRIPT_DIR/Tom's Fans.xcodeproj" \
    -showBuildSettings -scheme "Tom's Fans" -configuration Release 2>/dev/null \
    | sed -n 's/^[[:space:]]*BUILT_PRODUCTS_DIR = //p' | head -1)

echo ""
echo "✅ Build complete."
echo "   App: $APP_DIR/Tom's Fans.app"
echo ""
echo "Install the privileged helper with EITHER:"
echo "   • Launch the app and click 'Install Helper' (approve in System Settings), or"
echo "   • sudo ./install-helper.sh"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x build-release.sh
```

- [ ] **Step 3: Run it and verify the build + bundle layout**

Run: `./build-release.sh`
Expected: ends with `✅ Build complete.` and prints an `App:` path.

Then verify the bundle layout (substitute the printed `App:` path for `$APP`):

```bash
ls "$APP/Contents/Resources/com.tomsfans.helper"        # executable present
ls "$APP/Contents/Library/LaunchDaemons/"               # ONLY com.tomsfans.helper.plist
```
Expected: the executable exists in `Resources/`, and `LaunchDaemons/` contains **only** `com.tomsfans.helper.plist` (no `com.tomsfans.helper` binary).

- [ ] **Step 4: Confirm the embedded plist uses BundleProgram**

Run: `plutil -p "$APP/Contents/Library/LaunchDaemons/com.tomsfans.helper.plist" | grep -E "BundleProgram|ProgramArguments"`
Expected: shows `BundleProgram => "Contents/Resources/com.tomsfans.helper"` and no `ProgramArguments`.

- [ ] **Step 5: Commit**

```bash
git add build-release.sh
git commit -m "Add build-release.sh one-command Release build"
```

---

### Task 6: Update `install-helper.sh` — app scheme, Release default, system plist

Make the script locate the helper via the **app** scheme (which builds the helper as a dependency and is shared), default to **Release**, and install the absolute-path `launchd-system.plist`.

**Files:**
- Modify: `install-helper.sh`

- [ ] **Step 1: Point the build-settings query at the app scheme + Release**

Replace:

```bash
PROJECT_BUILD_DIR=$(sudo -u "$RUN_USER" xcodebuild -project "$SCRIPT_DIR/Tom's Fans.xcodeproj" -showBuildSettings -scheme "com.tomsfans.helper" -configuration Debug 2>/dev/null \
    | sed -n 's/^[[:space:]]*BUILT_PRODUCTS_DIR = //p' | head -1)
```

with:

```bash
PROJECT_BUILD_DIR=$(sudo -u "$RUN_USER" xcodebuild -project "$SCRIPT_DIR/Tom's Fans.xcodeproj" -showBuildSettings -scheme "Tom's Fans" -configuration Release 2>/dev/null \
    | sed -n 's/^[[:space:]]*BUILT_PRODUCTS_DIR = //p' | head -1)
```

- [ ] **Step 2: Point the DerivedData fallback at Release**

Replace:

```bash
    HELPER_PATH=$(find "$DERIVED_DATA" -name "com.tomsfans.helper" -type f -path "*/Debug/*" -print0 2>/dev/null \
```

with:

```bash
    HELPER_PATH=$(find "$DERIVED_DATA" -name "com.tomsfans.helper" -type f -path "*/Release/*" -print0 2>/dev/null \
```

- [ ] **Step 3: Update the "build first" hint to mention Release**

Replace:

```bash
    echo "Build the project in Xcode first (Cmd+B with 'com.tomsfans.helper' scheme)."
```

with:

```bash
    echo "Build the Release app first: ./build-release.sh (or Product > Build in Xcode)."
```

- [ ] **Step 4: Install the absolute-path system plist (not the bundle plist)**

Replace:

```bash
cp -f "$SCRIPT_DIR/Helper/launchd.plist" /Library/LaunchDaemons/com.tomsfans.helper.plist
```

with:

```bash
cp -f "$SCRIPT_DIR/Helper/launchd-system.plist" /Library/LaunchDaemons/com.tomsfans.helper.plist
```

- [ ] **Step 5: Verify syntax**

Run: `bash -n install-helper.sh && echo "syntax OK"`
Expected: `syntax OK`

- [ ] **Step 6: End-to-end verify the script install (requires the Release build from Task 5)**

```bash
sudo ./install-helper.sh
```
Expected: prints `Found helper at: …/Release/com.tomsfans.helper` and ends with `✅ Helper installed and running!`

Then confirm the daemon is loaded:

Run: `sudo launchctl print system/com.tomsfans.helper >/dev/null && echo LOADED`
Expected: `LOADED`

- [ ] **Step 7: Commit**

```bash
git add install-helper.sh
git commit -m "install-helper.sh: use app scheme, default to Release, install system plist"
```

---

### Task 7: Add an "Open Login Items Settings" button when approval is required

When SMAppService registration lands in `.requiresApproval`, give the user a one-click way to open the right Settings pane. Expose the check as a computed property on the service (keeps `ServiceManagement` contained in one file).

**Files:**
- Modify: `App/Services/HelperInstallService.swift`
- Modify: `App/Views/Main/SettingsView.swift`

- [ ] **Step 1: Add a `needsApproval` computed property**

In `App/Services/HelperInstallService.swift`, add after the `isHelperRunning` property (before the closing brace of the class):

```swift
    var needsApproval: Bool {
        status == .requiresApproval
    }
```

- [ ] **Step 2: Ensure AppKit is imported in SettingsView**

At the top of `App/Views/Main/SettingsView.swift`, if `import AppKit` is not already present, add it below the existing `import SwiftUI`:

```swift
import AppKit
```

- [ ] **Step 3: Add the button in the "Helper Tool" section**

In `App/Views/Main/SettingsView.swift`, replace:

```swift
                    Text("The helper tool runs with elevated privileges to control fan speeds. You'll be asked to approve it in System Settings > Login Items & Extensions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
```

with:

```swift
                    Text("The helper tool runs with elevated privileges to control fan speeds. You'll be asked to approve it in System Settings > Login Items & Extensions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if helperInstall.needsApproval {
                        Button("Open Login Items Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                } else {
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" -configuration Release build >/dev/null && echo BUILD_OK`
Expected: `BUILD_OK`

- [ ] **Step 5: Commit**

```bash
git add App/Services/HelperInstallService.swift "App/Views/Main/SettingsView.swift"
git commit -m "Add Open Login Items Settings button when helper needs approval"
```

---

### Task 8: Update the README for source-only distribution

Replace stale `SMJobBless` and "Download the latest release" language with build-from-source + both install paths.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Replace the Installation section**

Replace the existing `## Installation` section (the "Download the latest release…" paragraph and the first-launch note) with:

```markdown
## Requirements

- macOS 13 (Ventura) or later
- Xcode (to build from source)

## Building from source

This is a source-only release: clone the repo and build locally. The app is
**ad-hoc signed** and runs locally with no Apple Developer account required.

```bash
git clone <repo-url>
cd "Tom's Fans"
./build-release.sh
```

The script prints the path to the built `Tom's Fans.app`. (You can also open
`Tom's Fans.xcodeproj` in Xcode and build the **Tom's Fans** scheme.)

## Installing the privileged helper

Fan writes require a root helper that performs SMC writes. Install it **either** way:

- **In-app (recommended):** Launch the app, open Settings → Helper Tool, and click
  **Install Helper**. The helper is registered via `SMAppService`. macOS may show
  the status **"Requires Approval"** — enable *Tom's Fans* in
  System Settings → General → Login Items & Extensions (the app provides an
  **Open Login Items Settings** button).
- **Script (fallback):** `sudo ./install-helper.sh` copies the helper to
  `/Library/PrivilegedHelperTools/` and loads it as a system LaunchDaemon.

To remove the helper: `sudo ./uninstall-helper.sh`.
```

- [ ] **Step 2: Fix the architecture note about SMJobBless**

Replace:

```markdown
- **Privileged Helper** — a launchd-managed helper installed via `SMJobBless` that performs SMC writes with elevated privileges
```

with:

```markdown
- **Privileged Helper** — a launchd-managed helper registered via `SMAppService` (or installed by `install-helper.sh`) that performs SMC writes with elevated privileges
```

- [ ] **Step 3: Verify no stale references remain**

Run: `grep -rin "SMJobBless\|Download the latest release" README.md || echo "CLEAN"`
Expected: `CLEAN`

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "Docs: source-only build + install instructions, drop SMJobBless"
```

---

### Task 9: Full end-to-end verification

Confirm the whole flow works from the built Release app.

- [ ] **Step 1: Clean uninstall to start from a known state**

```bash
sudo ./uninstall-helper.sh
```
Expected: `✅ Helper uninstalled.`

- [ ] **Step 2: Script install path**

```bash
sudo ./install-helper.sh
sudo launchctl print system/com.tomsfans.helper >/dev/null && echo LOADED
```
Expected: install succeeds and prints `LOADED`.

- [ ] **Step 3: Launch the Release app and exercise fan control**

Launch the built `Tom's Fans.app`, confirm Settings → Helper Tool shows **Enabled**, and confirm setting a fan speed works (helper responds over XPC). Note the result.

- [ ] **Step 4: Verify the in-app button path (optional, on a clean state)**

`sudo ./uninstall-helper.sh`, relaunch the app, click **Install Helper**, approve in System Settings if prompted, and confirm status reaches **Enabled**.

- [ ] **Step 5: Final confirmation**

Confirm: fresh-clone build works (Task 1 + 5), bundle layout correct (Task 5), both install paths reach a working helper. The branch `source-release-prep` is ready to merge / tag as the source release.
```
