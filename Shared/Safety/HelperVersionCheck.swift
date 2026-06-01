import Foundation

/// Result of comparing the running helper's reported version against the version
/// this app build expects.
enum HelperVersionStatus: Equatable {
    /// Not probed yet, the probe failed, or the connection is down.
    case unknown
    /// The installed helper reports the expected version.
    case matched(String)
    /// A different helper version is installed — almost always an old daemon still
    /// running after an app update (the LaunchDaemon persists across upgrades).
    case mismatched(installed: String, expected: String)
}

/// Pure, dependency-free helper-version comparison.
///
/// `XPCConstants.helperVersion` is compiled into both the app and the helper from
/// `Shared/`, so a build of the two always agrees. A mismatch can therefore only mean
/// the installed helper binary is from a different build than the running app — the
/// stale-daemon-after-update case. Exact equality is the right policy: same constant,
/// built together, so any difference means "reinstall the embedded helper."
///
/// Holds no XPC or hardware state, so it is fully unit-testable.
enum HelperVersionCheck {
    /// Compare the helper's reported version (nil/empty when unknown) against the
    /// version this app build expects.
    static func evaluate(installed: String?, expected: String) -> HelperVersionStatus {
        guard let installed, !installed.isEmpty else { return .unknown }
        return installed == expected
            ? .matched(installed)
            : .mismatched(installed: installed, expected: expected)
    }
}
