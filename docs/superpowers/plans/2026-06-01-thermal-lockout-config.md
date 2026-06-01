# Configurable Thermal Ceiling + Lockout Latch Fix — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix the thermal-lockout latch bug and make the CPU thermal ceiling user-configurable (default 97 °C, range 50–100 °C, with an Off switch).

**Architecture:** Extract the lockout decision into a pure, hardware-free state machine (`ThermalLockoutState`) plus shared bounds (`ThermalCeiling`) under `Shared/Safety/`, unit-tested via a new host-free logic-test target. The helper consumes the state machine in its 1 Hz `safetyTick`; the app stores the ceiling/enabled flag in `AppSettings`, pushes them to the helper over the existing `setThermalGuard` XPC call, and exposes them in `SettingsView`.

**Tech Stack:** Swift 5.9, SwiftUI, XCTest, XcodeGen (`project.yml` → `.xcodeproj`), `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-06-01-thermal-lockout-config-design.md`

---

## File Structure

- **Create** `Shared/Safety/ThermalLockoutState.swift` — pure trip/clear state machine + `ThermalCeiling` bounds. Auto-compiled into the app and helper targets (both already include `path: Shared`).
- **Create** `Tests/ThermalLockoutStateTests.swift` — XCTest cases (regression for the latch + clamp).
- **Modify** `project.yml` — add `Tom's FansTests` logic-test target + scheme test action.
- **Modify** `Helper/FanControlServiceImpl.swift` — replace the `thermalLockout` Bool with `ThermalLockoutState`; reorder `safetyTick` guards; clamp the ceiling in `setThermalGuard`.
- **Modify** `App/Models/AppSettings.swift` — add `thermalLockoutEnabled` + `thermalCeilingC`.
- **Modify** `App/Services/XPCFanControlService.swift` — supply the ceiling/enabled from settings instead of a hardcoded 90.
- **Modify** `App/TomsFansApp.swift` — seed the XPC client's thermal config at bootstrap and re-arm live when settings change.
- **Modify** `App/Views/Main/SettingsView.swift` — "Thermal safety" section.

---

## Task 0: Branch

- [ ] **Step 1: Create a feature branch off master**

```bash
cd "/Users/thompson/Desktop/Tom's Fans"
git checkout -b thermal-lockout-config
```

---

## Task 1: Pure safety types + logic-test target

**Files:**
- Create: `Shared/Safety/ThermalLockoutState.swift`
- Create: `Tests/ThermalLockoutStateTests.swift`
- Modify: `project.yml`

- [ ] **Step 1: Write the pure state machine + bounds**

Create `Shared/Safety/ThermalLockoutState.swift`:

```swift
import Foundation

/// Shared bounds for the user-configurable CPU thermal ceiling.
/// Single source of truth for the app (settings + UI), the helper (clamp), and tests.
enum ThermalCeiling {
    static let minC: Double = 50
    static let maxC: Double = 100   // Tjmax on the target hardware; never arm above this
    static let defaultC: Double = 97

    static func clamp(_ value: Double) -> Double {
        Swift.min(Swift.max(value, minC), maxC)
    }
}

/// Pure, hardware-free thermal-lockout state machine.
///
/// Decides when to trip (revert fans to auto + reject forced writes) and when to
/// clear, from the guard-sensor temperature and a hysteresis band. Holds no SMC
/// state, so it is fully unit-testable. The helper owns the hardware reads and
/// applies the returned `Action`.
///
/// The original bug: the helper gated this evaluation behind "any fan forced", but
/// tripping reverts (un-forces) all fans — so the clear path became unreachable and
/// the lockout latched forever. Here, evaluation depends only on `lockedOut` and the
/// temperature, so cooldown always clears it (the caller must keep ticking while
/// `lockedOut`).
struct ThermalLockoutState {
    /// True while forced writes must be rejected.
    private(set) var lockedOut = false

    enum Action: Equatable {
        case none
        case trip    // crossed the ceiling: caller reverts fans to auto
        case clear   // dropped below the hysteresis band: lockout lifted
    }

    /// Evaluate one safety tick. Caller guarantees the guard is armed (`ceilingC > 0`)
    /// and `temp` is a valid reading.
    mutating func evaluate(fansForced: Bool, temp: Double,
                           ceilingC: Double, hysteresisC: Double) -> Action {
        guard lockedOut || fansForced else { return .none }
        if !lockedOut, temp >= ceilingC {
            lockedOut = true
            return .trip
        }
        if lockedOut, temp <= ceilingC - hysteresisC {
            lockedOut = false
            return .clear
        }
        return .none
    }

    /// Clear the lockout unconditionally (user disabled the guard).
    mutating func disable() {
        lockedOut = false
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/ThermalLockoutStateTests.swift`:

```swift
import XCTest

final class ThermalLockoutStateTests: XCTestCase {

    private let ceiling: Double = 97
    private let hysteresis: Double = 5   // clears at 92

    /// REGRESSION for the latch bug: after a trip the fans are reverted (no longer
    /// forced), yet the lockout must keep being evaluated and clear on cooldown.
    func testTripThenClearAfterCooldownWithNoFansForced() {
        var s = ThermalLockoutState()

        // Forced + at/above ceiling -> trip.
        XCTAssertEqual(s.evaluate(fansForced: true, temp: 97, ceilingC: ceiling, hysteresisC: hysteresis), .trip)
        XCTAssertTrue(s.lockedOut)

        // Trip reverted the fans -> fansForced is now false, still hot: stays locked.
        XCTAssertEqual(s.evaluate(fansForced: false, temp: 95, ceilingC: ceiling, hysteresisC: hysteresis), .none)
        XCTAssertTrue(s.lockedOut)

        // Cools to the hysteresis floor (92) -> clears, even with no fans forced.
        XCTAssertEqual(s.evaluate(fansForced: false, temp: 92, ceilingC: ceiling, hysteresisC: hysteresis), .clear)
        XCTAssertFalse(s.lockedOut)
    }

    func testStaysLockedInsideHysteresisBand() {
        var s = ThermalLockoutState()
        _ = s.evaluate(fansForced: true, temp: 98, ceilingC: ceiling, hysteresisC: hysteresis)
        // 93 is within (92, 97] -> still locked.
        XCTAssertEqual(s.evaluate(fansForced: false, temp: 93, ceilingC: ceiling, hysteresisC: hysteresis), .none)
        XCTAssertTrue(s.lockedOut)
    }

    func testNoTripWhenNotForcedAndNotLocked() {
        var s = ThermalLockoutState()
        XCTAssertEqual(s.evaluate(fansForced: false, temp: 99, ceilingC: ceiling, hysteresisC: hysteresis), .none)
        XCTAssertFalse(s.lockedOut)
    }

    func testDisableClearsLockout() {
        var s = ThermalLockoutState()
        _ = s.evaluate(fansForced: true, temp: 99, ceilingC: ceiling, hysteresisC: hysteresis)
        XCTAssertTrue(s.lockedOut)
        s.disable()
        XCTAssertFalse(s.lockedOut)
    }

    func testClampBounds() {
        XCTAssertEqual(ThermalCeiling.clamp(40), 50)
        XCTAssertEqual(ThermalCeiling.clamp(120), 100)
        XCTAssertEqual(ThermalCeiling.clamp(97), 97)
    }
}
```

- [ ] **Step 3: Add the logic-test target + scheme to `project.yml`**

Append a new target under `targets:` (sibling of `com.tomsfans.helper`):

```yaml
  Tom's FansTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - path: Tests
        excludes:
          - "**/.DS_Store"
      - path: Shared/Safety
        excludes:
          - "**/.DS_Store"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.tomsfans.tests
        GENERATE_INFOPLIST_FILE: true
        MACOSX_DEPLOYMENT_TARGET: "13.0"
        CODE_SIGN_IDENTITY: "-"
        CODE_SIGN_STYLE: Manual
        DEVELOPMENT_TEAM: ""
```

Add a top-level `schemes:` block (after the `targets:` block) so `xcodebuild test` knows what to run:

```yaml
schemes:
  Tom's Fans:
    build:
      targets:
        Tom's Fans: all
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - Tom's FansTests
```

- [ ] **Step 4: Regenerate the Xcode project**

Run: `cd "/Users/thompson/Desktop/Tom's Fans" && xcodegen generate`
Expected: `Created project at Tom's Fans.xcodeproj`

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```bash
xcodebuild test -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" \
  -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **` with `ThermalLockoutStateTests` (5 tests) passing.

(If the test types fail to resolve, confirm `Shared/Safety` is listed under the test target's `sources` — the pure files are compiled directly into the bundle, so no `@testable import` or test host is needed.)

- [ ] **Step 6: Commit**

```bash
git add "Shared/Safety/ThermalLockoutState.swift" Tests/ThermalLockoutStateTests.swift project.yml "Tom's Fans.xcodeproj"
git commit -m "Add pure ThermalLockoutState + ThermalCeiling with logic-test target"
```

---

## Task 2: Wire the state machine into the helper (latch fix)

**Files:**
- Modify: `Helper/FanControlServiceImpl.swift`

- [ ] **Step 1: Replace the `thermalLockout` Bool with the state machine**

In `Helper/FanControlServiceImpl.swift`, find:

```swift
    /// When tripped, forced writes are rejected until the sensor drops below the
    /// hysteresis band. Prevents the app from immediately re-forcing fans low.
    private var thermalLockout = false
```

Replace with:

```swift
    /// When tripped, forced writes are rejected until the sensor drops below the
    /// hysteresis band. Prevents the app from immediately re-forcing fans low.
    /// Pure state machine — see Shared/Safety/ThermalLockoutState.swift.
    private var lockout = ThermalLockoutState()
```

- [ ] **Step 2: Reorder `safetyTick` guards and drive the state machine**

Replace the whole `safetyTick()` method:

```swift
    private func safetyTick() {
        dispatchPrecondition(condition: .onQueue(smcQueue))
        guard let sensor = guardSensor, ceilingC > 0 else { return }
        // Keep ticking while locked out even though the trip un-forced every fan —
        // otherwise the clear path is unreachable and the lockout latches forever.
        guard lockout.lockedOut || !forcedFans.isEmpty else { return }
        guard let temp = try? reader.readTemperature(key: sensor) else { return }

        switch lockout.evaluate(fansForced: !forcedFans.isEmpty, temp: temp,
                                ceilingC: ceilingC, hysteresisC: Self.ceilingHysteresisC) {
        case .trip:
            NSLog("FanControlServiceImpl: thermal ceiling %.0fC reached (%.1fC) — reverting fans to auto",
                  ceilingC, temp)
            _ = performRestore(panic: true)
        case .clear:
            NSLog("FanControlServiceImpl: thermal lockout cleared (%.1fC)", temp)
        case .none:
            break
        }
    }
```

- [ ] **Step 3: Update the three remaining `thermalLockout` references**

In `setFanMinSpeed`, replace:

```swift
            guard !self.thermalLockout else {
```
with:
```swift
            guard !self.lockout.lockedOut else {
```

In `setFanMode`, replace:

```swift
            if mode != 0, self.thermalLockout {
```
with:
```swift
            if mode != 0, self.lockout.lockedOut {
```

In `setThermalGuard`, replace the `else` branch body:

```swift
            } else {
                // Disable the guard and clear any standing lockout.
                self.guardSensor = nil
                self.ceilingC = 0
                self.thermalLockout = false
            }
```
with:
```swift
            } else {
                // Disable the guard and clear any standing lockout.
                self.guardSensor = nil
                self.ceilingC = 0
                self.lockout.disable()
            }
```

- [ ] **Step 4: Clamp the incoming ceiling (defense in depth)**

In `setThermalGuard`, replace the `if` branch:

```swift
            if sensorKey.utf8.count == 4, ceilingC > 0 {
                self.guardSensor = FourCharCode(sensorKey)
                self.ceilingC = ceilingC
            } else {
```
with:
```swift
            if sensorKey.utf8.count == 4, ceilingC > 0 {
                self.guardSensor = FourCharCode(sensorKey)
                // Never arm above Tjmax — a higher "ceiling" would be worse than Off.
                self.ceilingC = min(ceilingC, ThermalCeiling.maxC)
            } else {
```

- [ ] **Step 5: Build the helper target to verify it compiles**

Run:
```bash
xcodebuild build -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" \
  -configuration Debug -destination 'platform=macOS' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Commit**

```bash
git add "Helper/FanControlServiceImpl.swift"
git commit -m "Fix thermal-lockout latch: drive safetyTick from ThermalLockoutState"
```

---

## Task 3: Settings model

**Files:**
- Modify: `App/Models/AppSettings.swift`

- [ ] **Step 1: Add the two published properties**

In `App/Models/AppSettings.swift`, after the `cpuDisplayMode` property (around line 99), add:

```swift
    @Published var thermalLockoutEnabled: Bool {
        didSet { UserDefaults.standard.set(thermalLockoutEnabled, forKey: "thermalLockoutEnabled") }
    }
    @Published var thermalCeilingC: Double {
        didSet {
            let clamped = ThermalCeiling.clamp(thermalCeilingC)
            if thermalCeilingC != clamped {
                thermalCeilingC = clamped   // one-level recursion; then equal -> persists
            } else {
                UserDefaults.standard.set(thermalCeilingC, forKey: "thermalCeilingC")
            }
        }
    }
```

- [ ] **Step 2: Initialize them in `init`**

In `init()`, after the `cpuDisplayMode` assignment (around line 138-139), add:

```swift
        self.thermalLockoutEnabled = (UserDefaults.standard.object(forKey: "thermalLockoutEnabled") as? Bool) ?? true
        let storedCeiling = UserDefaults.standard.double(forKey: "thermalCeilingC")
        self.thermalCeilingC = storedCeiling > 0 ? ThermalCeiling.clamp(storedCeiling) : ThermalCeiling.defaultC
```

(`didSet` does not fire for assignments in `init`, matching the existing properties.)

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
xcodebuild build -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" \
  -configuration Debug -destination 'platform=macOS' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add "App/Models/AppSettings.swift"
git commit -m "Add thermalLockoutEnabled + thermalCeilingC to AppSettings"
```

---

## Task 4: XPC client supplies the configured ceiling

**Files:**
- Modify: `App/Services/XPCFanControlService.swift`

- [ ] **Step 1: Replace the hardcoded ceiling with settings-driven fields**

In `App/Services/XPCFanControlService.swift`, find:

```swift
    /// Absolute CPU thermal ceiling the helper enforces while fans are forced.
    /// TCXC = Intel CPU package (PECI). TODO(#7): branch sensor for Apple Silicon;
    /// TODO: make the ceiling user-configurable in Settings.
    private static let thermalGuardSensor = "TCXC"
    private static let thermalGuardCeilingC: Double = 90
```

Replace with:

```swift
    /// Guard sensor the helper watches while fans are forced.
    /// TCXC = Intel CPU package (PECI). TODO(#7): branch sensor for Apple Silicon.
    private static let thermalGuardSensor = "TCXC"

    /// Thermal-guard config, mirrored from AppSettings (set at bootstrap and on change).
    var thermalLockoutEnabled = true
    var thermalCeilingC: Double = ThermalCeiling.defaultC
```

- [ ] **Step 2: Add a re-arm helper and use it when forcing**

In `setFanMode`, replace:

```swift
    func setFanMode(fanIndex: Int, mode: UInt8) {
        // Arm the helper's thermal failsafe whenever we take forced control.
        if mode == 1 {
            proxy?.setThermalGuard(sensorKey: Self.thermalGuardSensor,
                                   ceilingC: Self.thermalGuardCeilingC) { _, _ in }
        }
        proxy?.setFanMode(fanIndex: fanIndex, mode: mode) { [weak self] success, error in
```
with:
```swift
    func setFanMode(fanIndex: Int, mode: UInt8) {
        // Arm (or, if disabled, clear) the helper's thermal failsafe when we take forced control.
        if mode == 1 {
            updateThermalGuard()
        }
        proxy?.setFanMode(fanIndex: fanIndex, mode: mode) { [weak self] success, error in
```

Add this method just above `restoreAutomatic()`:

```swift
    /// Push the current thermal-guard config to the helper. A ceiling of 0 disables
    /// the guard (and clears any standing lockout) helper-side. Call when the user
    /// changes the setting while fans are already forced.
    func updateThermalGuard() {
        let ceiling = thermalLockoutEnabled ? thermalCeilingC : 0
        proxy?.setThermalGuard(sensorKey: Self.thermalGuardSensor, ceilingC: ceiling) { _, _ in }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
xcodebuild build -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" \
  -configuration Debug -destination 'platform=macOS' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add "App/Services/XPCFanControlService.swift"
git commit -m "Drive thermal guard from settings-supplied ceiling, not hardcoded 90"
```

---

## Task 5: Seed + live re-arm in the app

**Files:**
- Modify: `App/TomsFansApp.swift`

- [ ] **Step 1: Seed the XPC client's thermal config at bootstrap**

In `bootstrapIfNeeded()`, immediately after `fanControl.errorLog = errorLog` (around line 83), add:

```swift
        fanControl.thermalLockoutEnabled = settings.thermalLockoutEnabled
        fanControl.thermalCeilingC = settings.thermalCeilingC
```

(This runs before `reapplySavedMode()`, so a launch in curve/preset mode arms the guard with the correct ceiling.)

- [ ] **Step 2: Observe thermal-setting changes and re-arm live**

In `bootstrapIfNeeded()`, after the existing `observePollIntervalChanges()` call (around line 97), add a call:

```swift
        observeThermalSettings()
```

Add the method next to `observePollIntervalChanges()`:

```swift
    private func observeThermalSettings() {
        settings.$thermalLockoutEnabled
            .combineLatest(settings.$thermalCeilingC)
            .dropFirst()
            .sink { [weak fanControl, weak settings] enabled, ceiling in
                guard let fanControl, let settings else { return }
                fanControl.thermalLockoutEnabled = enabled
                fanControl.thermalCeilingC = ceiling
                // Re-arm immediately only if we're currently driving the fans.
                if settings.controlMode != .automatic {
                    fanControl.updateThermalGuard()
                }
            }
            .store(in: &Self.cancellables)
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run:
```bash
xcodebuild build -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" \
  -configuration Debug -destination 'platform=macOS' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add "App/TomsFansApp.swift"
git commit -m "Seed and live-re-arm the thermal guard from settings changes"
```

---

## Task 6: Settings UI

**Files:**
- Modify: `App/Views/Main/SettingsView.swift`

- [ ] **Step 1: Add the Thermal safety section**

In `App/Views/Main/SettingsView.swift`, insert a new `Section` immediately after the `Section("Temperature Alerts") { ... }` block (after its closing brace, around line 87):

```swift
            Section {
                Toggle("Revert to automatic if CPU gets too hot", isOn: $settings.thermalLockoutEnabled)

                HStack {
                    Stepper(value: $settings.thermalCeilingC,
                            in: ThermalCeiling.minC...ThermalCeiling.maxC,
                            step: 1) {
                        Text("Ceiling: \(Int(settings.thermalCeilingC))°C")
                            .monospacedDigit()
                    }
                    .disabled(!settings.thermalLockoutEnabled)
                }
            } header: {
                Text("Thermal Safety")
            } footer: {
                if settings.thermalLockoutEnabled {
                    Text("While a fan curve or manual speed is active, the helper reverts all fans to automatic if the CPU package reaches this temperature, then resumes once it cools. 90°C is normal under load on this hardware; the default 97°C leaves margin below the CPU's ~100°C throttle.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Forced and curve fan modes will have NO software thermal protection — only the CPU's built-in ~100°C throttle, which does not protect the GPU, VRMs, or battery. Crash protection (revert to automatic when the app exits) still applies.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
```

- [ ] **Step 2: Build to verify it compiles**

Run:
```bash
xcodebuild build -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" \
  -configuration Debug -destination 'platform=macOS' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add "App/Views/Main/SettingsView.swift"
git commit -m "Add Thermal Safety settings section (ceiling stepper + Off toggle)"
```

---

## Task 7: Full verification

- [ ] **Step 1: Run the full test suite**

Run:
```bash
xcodebuild test -project "Tom's Fans.xcodeproj" -scheme "Tom's Fans" \
  -destination 'platform=macOS' 2>&1 | tail -20
```
Expected: `** TEST SUCCEEDED **`

- [ ] **Step 2: Release build**

Run: `cd "/Users/thompson/Desktop/Tom's Fans" && ./build-release.sh`
Expected: `✅ Build complete.`

- [ ] **Step 3: Manual smoke test (requires installed helper + hardware)**

Verify each, since the helper/SMC paths are not unit-testable:
1. Settings → Thermal Safety shows the toggle + stepper; stepper greys out when the toggle is off; stepper clamps at 50 and 100.
2. With a fan curve active, change the ceiling — no crash; (if observable) the helper logs a new guard via `log stream --predicate 'process == "com.tomsfans.helper"'`.
3. Drive the CPU above the ceiling under a forced-low curve and confirm fans revert to auto, then — **the regression** — after cooldown the curve resumes (no permanent lockout, no Automatic toggle required).
4. Toggle the lockout Off; confirm forced writes are no longer rejected and the footer shows the orange warning.

- [ ] **Step 4: Final review**

Confirm all tasks committed and the branch is clean:
```bash
git status
git log --oneline thermal-lockout-config ^master
```

---

## Self-Review

**Spec coverage:**
- Latch fix (spec §A) → Task 1 (pure type + regression test) + Task 2 (helper wiring). ✓
- Settings model `thermalLockoutEnabled` / `thermalCeilingC` (spec §B) → Task 3. ✓
- XPC client supplies ceiling, 0 = disable (spec §C) → Task 4. ✓
- Live re-arm on change (spec §D) → Task 5. ✓
- Helper-side clamp to 100 (spec §E) → Task 2 Step 4. ✓
- UI toggle + stepper + caution text (spec §F) → Task 6. ✓
- Default 97, range 50–100 → `ThermalCeiling` constants (Task 1), stepper range (Task 6). ✓
- Testing: pure state machine extracted + unit-tested (spec Testing) → Task 1. ✓
- GPU/multi-sensor guard is explicitly a non-goal → not in plan. ✓

**Type consistency:** `ThermalLockoutState.evaluate(fansForced:temp:ceilingC:hysteresisC:)`, `.disable()`, `.lockedOut`, and `Action.{none,trip,clear}` are used identically in Task 1 (definition + tests) and Task 2 (helper). `ThermalCeiling.{minC,maxC,defaultC,clamp(_:)}` used identically across Tasks 1, 2, 3, 4, 6. `updateThermalGuard()` defined in Task 4 and called in Tasks 4 and 5. ✓

**Placeholder scan:** No TBD/TODO-as-work, no "add error handling", every code step shows complete code. ✓
