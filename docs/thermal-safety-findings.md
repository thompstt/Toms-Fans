# Thermal Safety Findings — Forced Fan Mode Overrides the OS

**Date:** 2026-05-29
**Hardware:** MacBook Pro 16,1 (Intel i9, 16 logical cores), macOS

## Question

When a fan is put under forced/manual control (`F*Md = 1` + a target RPM), does
macOS retain the ability to spin it *up* for thermal protection, or does the
forced value fully override the OS thermal loop?

The XPC protocol doc claimed the former:
> "The fan will run at least this speed; the OS can still increase it for thermal protection."

This claim was never verified, and the entire safety model of curve/manual mode
depends on which answer is true.

## Method

A load harness (`thermal-probe.sh`) drove a sustained CPU load while logging CPU
die temperature and fan RPM via `powermetrics --samplers smc`. The fan was pinned
using a **trusted third-party tool (Macs Fan Control)**, not this app, to isolate
the SMC's behavior from any bug in our own write path (notably the unverified
`flt` endianness). Auto-abort at a temperature ceiling; firmware thermal
protection as the ultimate backstop.

Two conditions were compared at matched temperatures:
1. **Auto** — macOS in control of the fan.
2. **Forced-at-minimum** — fan pinned at its hardware minimum (~1835 RPM).

## Data

**Auto** — fan holds at minimum until ~90 °C, then ramps hard:

| temp °C | fan RPM |
|--------:|--------:|
| 89.4 | 1838 |
| 90.6 | 1926 |
| 91.4 | 2076 |
| 93.7 | 2192 (climbing) |

**Forced-at-minimum** — fan stays flat through the same band:

| temp °C | fan RPM |
|--------:|--------:|
| 88.9 | 1834 |
| 91.4 | 1852 |
| 92.3 | 1841 |
| 93.8 | 1831 |

(The 1827–1852 spread is sensor noise, identical to idle readings.)

## Verdict

**Forced mode is a hard OVERRIDE, not a floor.**

At ~91 °C, macOS demonstrably *wanted* ~2076 RPM (proven by the Auto run) but,
with the fan forced to minimum, could only deliver ~1852. It could not raise the
fan above the forced value. The protocol comment is **false** and must be removed.

The only protection remaining under a low forced value is the SMC firmware's
hardware thermal throttle (~100 °C on this CPU). That is a last-ditch backstop,
not a feature to rely on.

## Consequences

1. **A helper-side thermal ceiling is mandatory.** A misconfigured curve
   (high temp → low %) will hold fans low while the chip overheats. The helper
   must read the driving sensor and, above a ceiling (~90 °C), revert affected
   fans to auto (`F*Md = 0`) — which is proven to make macOS ramp them.

2. **The dead-man's switch is critical, not optional.** If the app crashes while
   holding a forced-low value, macOS will *not* compensate (override confirmed).
   The helper reverting to auto on app death is the only thing that saves the
   machine in that scenario.

3. **Remove the misleading protocol comment** in `Shared/XPCProtocol/FanControlProtocol.swift`.

All three protections (ceiling, heartbeat/dead-man, duty-cycle throttle) belong
to a single root-side loop in the helper — see the unified safety loop spec.
