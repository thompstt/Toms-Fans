#if DEBUG
import Foundation

/// Fixture-driven sanity checks for ProcessSampler pure functions.
/// Called once during bootstrap in DEBUG builds; prints PASS/FAIL to console.
enum ProcessMonitorDebugHarness {

    static func run() {
        print("=== ProcessMonitor debug harness ===")
        testRateComputation()
        testLivePIDListing()
        print("=== harness done ===")
    }

    private static func testRateComputation() {
        let now = Date()
        let (raw, norm) = ProcessSampler.computeRate(
            prevCPUSeconds: 10.0,
            currCPUSeconds: 10.5,
            prevWall: now,
            currWall: now.addingTimeInterval(1.0),
            logicalCores: 16
        )
        assertClose("rate raw (0.5s/1s, 16c)", raw, 50.0)
        assertClose("rate normalized (0.5s/1s, 16c)", norm, 3.125)

        let (raw2, norm2) = ProcessSampler.computeRate(
            prevCPUSeconds: 0, currCPUSeconds: 1.0,
            prevWall: now, currWall: now.addingTimeInterval(1.0),
            logicalCores: 16
        )
        assertClose("rate raw (saturated core)", raw2, 100.0)
        assertClose("rate normalized (saturated core)", norm2, 6.25)

        let (raw3, norm3) = ProcessSampler.computeRate(
            prevCPUSeconds: 5.0, currCPUSeconds: 1.0,
            prevWall: now, currWall: now.addingTimeInterval(1.0),
            logicalCores: 16
        )
        assertClose("rate raw (negative delta)", raw3, 0.0)
        assertClose("rate normalized (negative delta)", norm3, 0.0)

        let (raw4, _) = ProcessSampler.computeRate(
            prevCPUSeconds: 0, currCPUSeconds: 1.0,
            prevWall: now, currWall: now,
            logicalCores: 16
        )
        assertClose("rate raw (zero wall delta)", raw4, 0.0)
    }

    private static func testLivePIDListing() {
        let pids = ProcessSampler.listAllPIDs()
        let pass = pids.count > 50
        print("\(pass ? "PASS" : "FAIL") listAllPIDs (got \(pids.count), expected > 50)")
        if pass, let firstPID = pids.first {
            let name = ProcessSampler.name(for: firstPID)
            let path = ProcessSampler.path(for: firstPID)
            print("       sample pid=\(firstPID) name=\(name) path=\(path)")
        }
    }

    private static func assertClose(_ label: String, _ a: Double, _ b: Double, tol: Double = 0.001) {
        let pass = abs(a - b) <= tol
        print("\(pass ? "PASS" : "FAIL") \(label): got \(a), expected \(b)")
    }
}
#endif
