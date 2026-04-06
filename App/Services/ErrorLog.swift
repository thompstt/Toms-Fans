import Foundation

// MARK: - Data Types

struct ErrorEntry: Identifiable {
    let id = UUID()
    let date: Date
    let source: ErrorSource
    let severity: ErrorSeverity
    let message: String
}

enum ErrorSource: String {
    case smc = "SMC"
    case xpc = "XPC"
}

enum ErrorSeverity: Comparable {
    case warning
    case critical
}

// MARK: - Error Log Service

final class ErrorLog: ObservableObject {
    @Published private(set) var currentToast: ErrorEntry?
    @Published private(set) var activeConditions: [String: ErrorEntry] = [:]
    @Published private(set) var entries: [ErrorEntry] = []

    private let maxEntries = 200
    private var toastDismissWork: DispatchWorkItem?

    // MARK: - Transient Errors (toast)

    func logTransient(_ message: String, source: ErrorSource) {
        let entry = ErrorEntry(date: Date(), source: source,
                               severity: .warning, message: message)
        appendToLog(entry)
        showToast(entry)
    }

    // MARK: - Persistent Conditions (banner)

    func setCondition(id: String, message: String, source: ErrorSource,
                      severity: ErrorSeverity) {
        let entry = ErrorEntry(date: Date(), source: source,
                               severity: severity, message: message)
        activeConditions[id] = entry
        appendToLog(entry)
    }

    func clearCondition(id: String) {
        activeConditions.removeValue(forKey: id)
    }

    // MARK: - Log Management

    func clearLog() {
        entries.removeAll()
    }

    func dismissToast() {
        toastDismissWork?.cancel()
        currentToast = nil
    }

    // MARK: - Internal

    private func appendToLog(_ entry: ErrorEntry) {
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    private func showToast(_ entry: ErrorEntry) {
        currentToast = entry
        toastDismissWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.currentToast = nil
        }
        toastDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}
