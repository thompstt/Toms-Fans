import Foundation

/// High-level read-only interface to the SMC.
/// Reads temperatures, fan speeds, and discovers available sensors.
final class SMCReader {
    private let connection: SMCConnection
    private var keyInfoCache: [FourCharCode: SMCKeyInfoData] = [:]

    init(connection: SMCConnection) {
        self.connection = connection
    }

    /// Clear cached key info. Call after reconnecting the SMC
    /// so stale data-type lookups don't cause misreads.
    func clearCache() {
        keyInfoCache.removeAll()
    }

    // MARK: - Key Info

    /// Get the data type and size for an SMC key (cached after first lookup).
    func getKeyInfo(_ key: FourCharCode) throws -> SMCKeyInfoData {
        if let cached = keyInfoCache[key] { return cached }
        var input = SMCParamStruct()
        input.key = key
        input.data8 = SMCSelector.kSMCGetKeyInfo.rawValue
        let output = try connection.callDriver(input: &input)
        keyInfoCache[key] = output.keyInfo
        return output.keyInfo
    }

    // MARK: - Raw Read

    /// Read raw bytes from an SMC key. Returns (dataType, bytes).
    func readKey(_ key: FourCharCode) throws -> (dataType: UInt32, bytes: SMCBytes) {
        // Step 1: Get key info to know the data type and size
        let info = try getKeyInfo(key)

        // Step 2: Read the actual value
        var input = SMCParamStruct()
        input.key = key
        input.data8 = SMCSelector.kSMCReadKey.rawValue
        input.keyInfo.dataSize = info.dataSize
        let output = try connection.callDriver(input: &input)

        return (info.dataType, output.bytes)
    }

    // MARK: - Temperature Reading

    /// Read a temperature sensor value in Celsius.
    func readTemperature(key: FourCharCode) throws -> Double {
        let (dataType, bytes) = try readKey(key)

        if dataType == SMCDataType.sp78 {
            return Double(sp78: bytes.0, byte1: bytes.1)
        } else if dataType == SMCDataType.flt {
            return Double(flt: bytes)
        } else {
            throw SMCError.unexpectedDataType(dataType)
        }
    }

    // MARK: - Fan Reading

    /// Get the number of fans in the system.
    func fanCount() throws -> Int {
        let (_, bytes) = try readKey(SMCKey.fanCount)
        return Int(bytes.0)
    }

    /// Read the current actual fan speed in RPM.
    func fanActualSpeed(fanIndex: Int) throws -> Double {
        let (dataType, bytes) = try readKey(SMCKey.fanActual(fanIndex))

        if dataType == SMCDataType.flt {
            return Double(flt: bytes)
        }
        return Double(fpe2: bytes.0, byte1: bytes.1)
    }

    /// Read the current minimum fan speed in RPM.
    func fanMinSpeed(fanIndex: Int) throws -> Double {
        let (dataType, bytes) = try readKey(SMCKey.fanMin(fanIndex))

        if dataType == SMCDataType.flt {
            return Double(flt: bytes)
        }
        return Double(fpe2: bytes.0, byte1: bytes.1)
    }

    /// Read the maximum fan speed in RPM.
    func fanMaxSpeed(fanIndex: Int) throws -> Double {
        let (dataType, bytes) = try readKey(SMCKey.fanMax(fanIndex))

        if dataType == SMCDataType.flt {
            return Double(flt: bytes)
        }
        return Double(fpe2: bytes.0, byte1: bytes.1)
    }

    // MARK: - Sensor Discovery

    /// Enumerate all SMC keys and return temperature sensors.
    /// This discovers every sensor the hardware has, regardless of whether
    /// we have a human-friendly name for it.
    func discoverTemperatureSensors() throws -> [(key: String, name: String, value: Double)] {
        // Get total key count
        let (_, countBytes) = try readKey(SMCKey.keyCount)
        let totalKeys = Int(ui32: countBytes)

        var sensors: [(key: String, name: String, value: Double)] = []

        for i in 0..<totalKeys {
            // Get key at index
            var input = SMCParamStruct()
            input.data8 = SMCSelector.kSMCGetKeyFromIndex.rawValue
            input.data32 = UInt32(i)
            let output = try connection.callDriver(input: &input)

            let keyCode = output.key
            let keyStr = keyCode.fourCharString

            // Temperature keys start with 'T'
            guard keyStr.hasPrefix("T") else { continue }

            // Try to read as temperature
            guard let temp = try? readTemperature(key: keyCode),
                  temp > 0, temp < 130 else { continue }

            let name = KnownSensors.name(for: keyStr) ?? keyStr
            sensors.append((key: keyStr, name: name, value: temp))
        }

        return sensors
    }

    /// Discover all fans and return their current state.
    func discoverFans() throws -> [(index: Int, actual: Double, min: Double, max: Double)] {
        let count = try fanCount()
        var fans: [(index: Int, actual: Double, min: Double, max: Double)] = []

        for i in 0..<count {
            let actual = (try? fanActualSpeed(fanIndex: i)) ?? 0
            let min = (try? fanMinSpeed(fanIndex: i)) ?? 0
            let max = (try? fanMaxSpeed(fanIndex: i)) ?? 0
            fans.append((index: i, actual: actual, min: min, max: max))
        }

        return fans
    }
}
