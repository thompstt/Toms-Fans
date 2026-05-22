import Foundation
import IOKit
import Darwin

/// Implementation of the FanControlProtocol that performs privileged SMC writes.
/// Runs inside the helper tool under root.
final class FanControlServiceImpl: NSObject, FanControlProtocol {
    private let connection = SMCConnection()
    private var originalMinSpeeds: [Int: Double] = [:]
    private var originalModes: [Int: UInt8] = [:]

    private static let neverSignalNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow",
        "logd", "mds", "mds_stores", "com.tomsfans.helper", "Tom's Fans"
    ]
    private static let allowedSignals: Set<Int32> = [SIGTERM, SIGKILL, SIGSTOP, SIGCONT]

    override init() {
        super.init()
        do {
            try connection.open()
            cacheOriginalState()
        } catch {
            NSLog("FanControlServiceImpl: Failed to open SMC: \(error)")
        }
    }

    // MARK: - FanControlProtocol

    func setFanMinSpeed(fanIndex: Int, rpm: Int,
                        withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            // Write to F*Tg (target), not F*Mn (min) — F*Mn is read-only on MacBook Pro 16,1
            try writeFanFloat(key: SMCKey.fanTarget(fanIndex), value: Float(rpm))
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func setFanMode(fanIndex: Int, mode: UInt8,
                    withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            try writeUInt8(key: SMCKey.fanMode(fanIndex), value: mode)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func restoreAutomaticControl(withReply reply: @escaping (Bool, String?) -> Void) {
        var errors: [String] = []

        // Restore original modes (set back to 0 = auto)
        for (index, _) in originalModes {
            do {
                try writeUInt8(key: SMCKey.fanMode(index), value: 0)
            } catch {
                errors.append("Fan \(index) mode: \(error)")
            }
        }

        if errors.isEmpty {
            reply(true, nil)
        } else {
            reply(false, errors.joined(separator: "; "))
        }
    }

    func getHelperVersion(withReply reply: @escaping (String) -> Void) {
        reply(XPCConstants.helperVersion)
    }

    func sendSignal(_ signal: Int32, toPID pid: pid_t,
                    withReply reply: @escaping (Bool, String?) -> Void) {
        guard Self.allowedSignals.contains(signal) else {
            reply(false, "signal \(signal) not allowed")
            return
        }
        guard pid > 1 else {
            reply(false, "PID \(pid) is protected (kernel/launchd)")
            return
        }
        if pid == getpid() {
            reply(false, "refused to signal helper itself")
            return
        }
        var nameBuf = [CChar](repeating: 0, count: 1024)
        let written = proc_name(pid, &nameBuf, UInt32(nameBuf.count))
        if written > 0 {
            let name = String(cString: nameBuf)
            if Self.neverSignalNames.contains(name) {
                reply(false, "process \(name) is on the never-signal list")
                return
            }
        }
        let result = kill(pid, signal)
        if result == 0 {
            reply(true, nil)
        } else {
            reply(false, "kill(\(pid), \(signal)) failed: errno=\(errno)")
        }
    }

    // MARK: - Private

    private func cacheOriginalState() {
        let reader = SMCReader(connection: connection)
        guard let count = try? reader.fanCount() else { return }

        for i in 0..<count {
            if let min = try? reader.fanMinSpeed(fanIndex: i) {
                originalMinSpeeds[i] = min
            }
            // Read current mode
            if let (_, bytes) = try? reader.readKey(SMCKey.fanMode(i)) {
                originalModes[i] = bytes.0
            }
        }
        NSLog("FanControlServiceImpl: Cached original state for \(count) fans")
        NSLog("  Min speeds: \(originalMinSpeeds)")
        NSLog("  Modes: \(originalModes)")
    }

    private func writeFanFloat(key: FourCharCode, value: Float) throws {
        // Get key info first — SMC validates both dataType AND dataSize on writes
        let reader = SMCReader(connection: connection)
        let info = try reader.getKeyInfo(key)

        var input = SMCParamStruct()
        input.key = key
        input.data8 = SMCSelector.kSMCWriteKey.rawValue
        input.keyInfo.dataSize = info.dataSize
        input.keyInfo.dataType = info.dataType

        // Write float in little-endian (native on Intel)
        withUnsafeBytes(of: value) { srcBytes in
            withUnsafeMutableBytes(of: &input.bytes) { destBytes in
                for i in 0..<4 {
                    destBytes[i] = srcBytes[i]
                }
            }
        }

        _ = try connection.callDriver(input: &input)
    }

    private func writeUInt8(key: FourCharCode, value: UInt8) throws {
        let reader = SMCReader(connection: connection)
        let info = try reader.getKeyInfo(key)

        var input = SMCParamStruct()
        input.key = key
        input.data8 = SMCSelector.kSMCWriteKey.rawValue
        input.keyInfo.dataSize = info.dataSize
        input.keyInfo.dataType = info.dataType

        withUnsafeMutableBytes(of: &input.bytes) { bytes in
            bytes[0] = value
        }

        _ = try connection.callDriver(input: &input)
    }
}
