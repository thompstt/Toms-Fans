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
