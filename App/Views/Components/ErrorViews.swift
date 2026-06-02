import SwiftUI

// MARK: - Toast (transient, auto-dismissing)

struct ErrorToastView: View {
    let entry: ErrorEntry
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.source.rawValue)
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                Text(entry.message)
                    .font(.caption)
                    .lineLimit(2)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .frame(maxWidth: 400)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Helper-not-enabled Banner (actionable)

/// Shown on the dashboard when the privileged helper isn't enabled, so the user
/// isn't left with fans that silently can't be controlled. Dumb on purpose — the
/// caller supplies the message, button title, and action (open Login Items / install).
struct HelperStatusBanner: View {
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
            Text(message)
                .font(.caption)
            Spacer()
            Button(actionTitle, action: action)
                .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .foregroundStyle(Color.orange)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Persistent Banner (stays until condition resolves)

struct ErrorBannerView: View {
    let conditions: [String: ErrorEntry]

    private var sorted: [ErrorEntry] {
        conditions.values.sorted { $0.severity > $1.severity }
    }

    private var highest: ErrorSeverity {
        sorted.first?.severity ?? .warning
    }

    private var color: Color {
        highest == .critical ? .red : .orange
    }

    private var icon: String {
        highest == .critical
            ? "exclamationmark.octagon.fill"
            : "exclamationmark.triangle.fill"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sorted) { entry in
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(.caption)
                    Text(entry.message)
                        .font(.caption)
                    Spacer()
                    Text(entry.source.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12))
        .foregroundStyle(color)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.3), lineWidth: 1)
        )
    }
}
