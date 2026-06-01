# Tom's Fans

**macOS fan monitoring & control for Apple Silicon and Intel Macs.**

![Dashboard](screenshot-dashboard.png)
![Menu Bar](screenshot-menubar.png)

## Features

- **Real-time temperature monitoring** — view CPU, GPU, and other sensor temperatures with live charts
- **4 control modes** — Auto (system default), Manual (fixed percentage), Curve (temperature-based), and Preset
- **Custom fan curves** — define temperature-to-speed curves with a visual editor
- **Presets** — save and quickly switch between fan configurations
- **Menu bar mode** — run as a compact menu bar app with quick controls
- **Notifications** — get alerts when temperatures exceed thresholds
- **Dashboard** — at-a-glance view of all fans and temperatures with gauges and graphs
- **Graceful sleep/wake** — automatically restores system fan control before sleep, reconnects to the SMC on wake, and re-applies your settings
- **Error reporting** — transient toast notifications, persistent dashboard banners for critical issues, and a terminal-style error log in Settings
- **Thermal safety** — automatically restores OS fan control if the SMC becomes unresponsive, the fan curve sensor disappears, or the helper connection is lost

Lightweight — ~1–2% CPU on a 2019 i9 MacBook Pro, ~60 MB memory.

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon or Intel Mac
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

## Usage

### Dashboard

The main window shows all detected fans with speed gauges, temperature sensors with live charts, and quick controls for each fan.

### Control Modes

| Mode | Description |
|------|-------------|
| **Auto** | System manages fan speed (default macOS behavior) |
| **Manual** | Set a fixed fan speed percentage |
| **Curve** | Fan speed follows a custom temperature-to-speed curve |
| **Preset** | Apply a saved configuration |

### Fan Curves

Open the curve editor to define control points mapping temperature ranges to fan speeds. The graph provides a visual preview of the response curve.

### Menu Bar Mode

Enable menu-bar-only mode in Settings to hide the dock icon and run entirely from the menu bar. The menu bar icon shows a quick summary and allows mode switching.

### Settings

Configure temperature units, notification thresholds, launch-at-login, menu bar behavior, and helper tool management. The Error Log section shows timestamped diagnostic messages from the current session.

## Architecture

```
Tom's Fans
├── App                    SwiftUI application (dashboard, settings, menu bar)
├── Helper                 Privileged helper tool (writes to SMC via XPC)
├── Shared/SMCKit          SMC read/write interface (IOKit)
└── Shared/XPCProtocol     XPC communication protocol
```

- **App** — SwiftUI frontend providing monitoring views, fan controls, and curve editing
- **Privileged Helper** — a launchd-managed helper registered via `SMAppService` (or installed by `install-helper.sh`) that performs SMC writes with elevated privileges
- **XPC** — secure inter-process communication between the app and the helper
- **SMCKit** — low-level System Management Controller access via IOKit for reading temperatures and fan data

Built entirely with Apple frameworks: SwiftUI, IOKit, ServiceManagement, UserNotifications, and Combine.

## Task Manager (experimental)

Tom's Fans can identify processes that are sustaining heavy CPU load and likely causing heat. When detected, a banner appears with one-click actions to Quit, Force Quit, or temporarily Throttle the process.

**Enable in Settings → Task Manager.** Process monitoring is on by default; remediation actions are opt-in.

**Safety note:** when you Throttle a process, Tom's Fans suspends it (SIGSTOP) for up to 10 seconds, then automatically resumes it (SIGCONT). The app guarantees this auto-resume runs on every normal exit path — including sleep, helper disconnect, and quit.

**Known limitation:** if Tom's Fans itself crashes (not a clean quit) while a process is throttled, that process will remain suspended. To unstick it manually: `kill -CONT <pid>`.

## Disclaimer

**Use at your own risk.** Overriding system fan controls can cause hardware to overheat. This software is provided as-is with no warranty. The authors are not responsible for any hardware damage resulting from improper fan configuration.

The app includes multiple safety layers: it restores automatic fan control before sleep, on helper disconnection, when the configured curve sensor disappears, and after sustained SMC read failures. The Mac's SMC firmware also provides its own hardware-level thermal protection independent of any software.

## License

This project is licensed under the [MIT License](LICENSE).
