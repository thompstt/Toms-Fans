import Foundation
import IOKit

/// Low-level connection to the AppleSMC IOKit service.
/// Handles open/close lifecycle and raw struct method calls.
final class SMCConnection {
    private var connection: io_connect_t = 0
    private var isOpen = false

    deinit {
        if isOpen { close() }
    }

    /// Open a connection to the AppleSMC kernel extension.
    func open() throws {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard service != 0 else {
            throw SMCError.serviceNotFound
        }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)

        guard result == kIOReturnSuccess else {
            throw SMCError.openFailed(result)
        }
        isOpen = true
    }

    /// Close and reopen the SMC connection.
    /// Call after sleep/wake — the IOKit handle may become stale.
    func reconnect() throws {
        close()
        try open()
    }

    /// Close the SMC connection.
    func close() {
        if isOpen {
            IOServiceClose(connection)
            connection = 0
            isOpen = false
        }
    }

    /// Send a command to the SMC driver and return the response.
    /// All SMC operations go through IOConnectCallStructMethod with selector 2.
    func callDriver(input: inout SMCParamStruct) throws -> SMCParamStruct {
        var output = SMCParamStruct()
        let inputSize = MemoryLayout<SMCParamStruct>.stride
        var outputSize = MemoryLayout<SMCParamStruct>.stride

        let result = IOConnectCallStructMethod(
            connection,
            UInt32(SMCSelector.kSMCHandleYPCEvent.rawValue),
            &input,
            inputSize,
            &output,
            &outputSize
        )

        guard result == kIOReturnSuccess else {
            throw SMCError.callFailed(result)
        }

        guard output.result == 0 else {
            throw SMCError.smcError(output.result)
        }

        return output
    }
}
