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

    func testReTripAfterClear() {
        var s = ThermalLockoutState()
        _ = s.evaluate(fansForced: true, temp: 97, ceilingC: ceiling, hysteresisC: hysteresis)
        XCTAssertEqual(s.evaluate(fansForced: false, temp: 92, ceilingC: ceiling, hysteresisC: hysteresis), .clear)
        // Heats back up while forced again -> trips a second time (machine is reusable).
        XCTAssertEqual(s.evaluate(fansForced: true, temp: 97, ceilingC: ceiling, hysteresisC: hysteresis), .trip)
        XCTAssertTrue(s.lockedOut)
    }

    func testNoTripJustBelowCeiling() {
        var s = ThermalLockoutState()
        XCTAssertEqual(s.evaluate(fansForced: true, temp: 96.999, ceilingC: ceiling, hysteresisC: hysteresis), .none)
        XCTAssertFalse(s.lockedOut)
    }

    func testClampBounds() {
        XCTAssertEqual(ThermalCeiling.clamp(40), 50)
        XCTAssertEqual(ThermalCeiling.clamp(120), 100)
        XCTAssertEqual(ThermalCeiling.clamp(97), 97)
    }
}
