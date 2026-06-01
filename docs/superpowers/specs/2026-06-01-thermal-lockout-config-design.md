# Configurable Thermal Ceiling + Lockout Latch Fix — Design

**Date:** 2026-06-01
**Hardware context:** MacBook Pro 16,1 (Intel i9), where ~90 °C is a normal operating
temperature under even mild load — making the current hardcoded 90 °C lockout
fire during ordinary use.

## Background

The helper enforces a thermal ceiling while any fan is forced: if the guard
sensor reaches the ceiling, it reverts all fans to auto and refuses further
forced writes until the temperature drops below a hysteresis band. This is the
only software protection against a misconfigured curve holding fans low while the
chip overheats, because forced mode is a hard override of the OS thermal loop
(see `docs/thermal-safety-findings.md`).

Two problems motivate this work:

1. **Latch bug.** Once the ceiling trips, the lockout never clears. `safetyTick`
   early-returns when `forcedFans.isEmpty`, but tripping the ceiling calls
   `performRestore`, which empties `forcedFans`. The hysteresis-clear branch
   therefore becomes unreachable, and `thermalLockout` stays `true` for the
   helper's lifetime (the helper is a persistent LaunchDaemon, so this survives
   app restarts). Recovery requires an explicit Automatic toggle or helper reload.

2. **Miscalibrated, non-configurable ceiling.** 90 °C is hardcoded in
   `XPCFanControlService`. On this hardware 90 °C is normal under mild load, so
   the lockout fights legitimate curves. 90 °C is also below where it needs to be:
   Tjmax on these chips is ~100 °C, so there is room for a higher ceiling that
   still engages before the CPU's own throttle.

## Goals

- Make a ceiling trip a brief, self-clearing revert instead of a permanent latch.
- Let the user adjust the ceiling, with an explicit option to disable it.
- Keep the change focused and testable.

## Non-Goals

- **GPU / multi-sensor guard.** The guard remains CPU-only (TCXC). Extending it to
  also watch the discrete GPU (TG0P) and other sensors is a real follow-up — as
  this change relaxes CPU protection, the GPU/VRM/battery have no ceiling backstop
  (only the CPU's ~100 °C throttle, which does not protect them). Deferred to its
  own spec because it requires a multi-sensor XPC API change.
- Apple-Silicon sensor branching (existing TODO #7).

## Design

### A. Latch fix (`Helper/FanControlServiceImpl.swift`)

Reorder `safetyTick`'s guards so the hysteresis-clear branch stays reachable while
locked out (when `forcedFans` is empty):

```swift
guard let sensor = guardSensor, ceilingC > 0 else { return }
guard thermalLockout || !forcedFans.isEmpty else { return }
guard let temp = try? reader.readTemperature(key: sensor) else { return }
```

After a trip: `forcedFans` is empty but `thermalLockout` is true, so the tick keeps
running, reads the sensor each second, and clears the lockout at
`ceilingC − ceilingHysteresisC` (5 °C). The app re-forces on its next poll. When
the lockout is disabled (`ceilingC == 0`), the first guard early-returns — no reads,
no trips.

This fix is a prerequisite for the configurable ceiling: without it, even a 97 °C
trip would latch permanently.

### B. Settings model (`App/Models/AppSettings.swift`)

Two new persisted properties, following the existing `@Published` + `didSet`
UserDefaults pattern:

```swift
@Published var thermalLockoutEnabled: Bool      // default true
@Published var thermalCeilingC: Double           // default 97, clamped 50...100 on set
```

- Keys: `thermalLockoutEnabled`, `thermalCeilingC`.
- `thermalCeilingC` is clamped to `50...100` in its `didSet` before persisting.
- Defaults applied in `init` when the keys are absent (97 / true).

### C. XPC client (`App/Services/XPCFanControlService.swift`)

- Remove the hardcoded `thermalGuardCeilingC = 90`. The ceiling and enabled flag
  are supplied by the caller (wired from `AppSettings`).
- When arming the guard on forced control, pass
  `ceilingC = enabled ? thermalCeilingC : 0`. A value of 0 uses the helper's
  existing "disable guard + clear lockout" path, so no new XPC method is needed.
- `thermalGuardSensor` stays `"TCXC"`.

### D. Live re-arm (`App/TomsFansApp.swift`)

Add a Combine observer (mirroring `observePollIntervalChanges`) on
`thermalLockoutEnabled` and `thermalCeilingC`. When either changes **and fans are
currently forced**, push the new value to the helper immediately via
`setThermalGuard` (or disable when toggled off). Changing the setting takes effect
live, not only on the next force.

### E. Helper-side clamp (`Helper/FanControlServiceImpl.swift`)

Defense in depth: in `setThermalGuard`, clamp any incoming `ceilingC > 0` to a hard
max of 100 °C before storing, so the app can never arm an above-Tjmax "ceiling"
that would be effectively worse than Off. Values ≤ 0 continue to disable the guard
and clear any standing lockout.

### F. UI (`App/Views/Main/SettingsView.swift`)

A "Thermal safety" row:

- A toggle bound to `thermalLockoutEnabled`, labelled "Revert to automatic if CPU
  exceeds…".
- A `Stepper` bound to `thermalCeilingC`, range `50...100`, step 1 °C, showing the
  current value; disabled/greyed when the toggle is off.
- When the toggle is off, inline caution text: "Forced and curve fan modes will
  have no software thermal protection — only the CPU's built-in ~100 °C throttle.
  Crash protection (revert on app exit) still applies."

## Behavior Summary

- **Default (enabled, 97 °C):** trips at 97 °C, reverts fans to auto + locks out,
  self-clears at 92 °C, app re-forces. 90 °C normal operation no longer trips.
- **Disabled:** no ceiling enforcement; forced/curve modes rely only on the CPU's
  own throttle. The dead-man's switch (revert on app exit/crash) is unaffected.
- **Notifications:** unchanged. `alertThresholds` (TCXC 95 °C) still warn before the
  default 97 °C ceiling acts.

## Safety Notes

- The **dead-man's switch is independent** of this setting. Disabling the lockout
  removes only the misconfigured-curve-while-running protection, not crash
  protection.
- The CPU-only coverage gap (GPU/VRM/battery) is unchanged by this work and tracked
  as the deferred multi-sensor guard.

## Testing

- **Latch fix:** the lockout state machine (set at ceiling, clear at
  ceiling − hysteresis, gated on enabled) should be extracted into a pure,
  hardware-free type so the trip→cooldown→clear sequence can be unit-tested
  without live SMC reads. This is also the cleanest way to lock in a regression
  test for the original bug.
- **Settings:** clamp behavior (50…100), persistence round-trip, default values.
- **Wiring:** changing the ceiling/toggle while forced re-arms the helper;
  toggling off disables and clears any standing lockout.

## Out-of-Scope Follow-ups

- Multi-sensor (GPU/VRM) thermal guard — next spec.
- Helper-side max-throttle-duration backstop and helper→app trip notification
  (identified in the prior safety audit; independent of this change).
