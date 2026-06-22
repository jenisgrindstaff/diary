import Foundation
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Query(sort: \PendingChange.createdAt, order: .forward) private var pendingChanges: [PendingChange]

    @State private var syncCoordinator = SyncCoordinator()
    @State private var healthCheckState = HealthCheckState.idle

    var body: some View {
        @Bindable var appState = appState

        NavigationStack {
            Form {
                Section("Server") {
                    TextField("https://diary.example.com", text: $appState.serverURLString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    SecureField("Access token", text: $appState.accessToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    LabeledContent {
                        Text(appState.tokenStateLabel)
                            .foregroundStyle(tokenStateColor)
                    } label: {
                        Label("Token", systemImage: tokenStateSymbolName)
                    }

                    if healthCheckState != .idle {
                        LabeledContent {
                            Text(healthCheckState.label)
                                .foregroundStyle(healthCheckState.color)
                        } label: {
                            Label("Health", systemImage: healthCheckState.symbolName)
                        }
                    }

                    Button("Use Local Server", systemImage: "house") {
                        appState.configureLocalDevelopmentServer()
                        healthCheckState = .idle
                    }

                    Button("Save Settings", systemImage: "checkmark") {
                        appState.saveSettings()
                    }

                    Button("Check Server Health", systemImage: "stethoscope") {
                        Task {
                            await checkServerHealth()
                        }
                    }
                    .disabled(healthCheckState == .checking || appState.serverURL == nil)
                }

                Section("Device") {
                    LabeledContent("Device ID", value: appState.deviceID)

                    LabeledContent {
                        Text(appState.registrationStateLabel)
                            .foregroundStyle(registrationStateColor)
                    } label: {
                        Label("Registration", systemImage: registrationStateSymbolName)
                    }

                    if !appState.registeredDeviceName.isEmpty {
                        LabeledContent("Registered As", value: appState.registeredDeviceName)
                    }

                    Button(registerDeviceTitle, systemImage: "iphone.gen3.radiowaves.left.and.right") {
                        appState.saveSettings()
                        Task {
                            await syncCoordinator.registerDevice(appState: appState)
                        }
                    }
                    .disabled(appState.serverURL == nil || appState.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section("Sync") {
                    LabeledContent {
                        Text(appState.syncStatus.label)
                            .foregroundStyle(statusColor)
                    } label: {
                        Label("Status", systemImage: appState.syncStatus.symbolName)
                    }

                    if !pendingChanges.isEmpty {
                        NavigationLink {
                            SyncActivityView()
                        } label: {
                            LabeledContent {
                                Text("\(pendingChanges.count)")
                                    .foregroundStyle(hasFailedPendingChanges ? .red : .secondary)
                            } label: {
                                Label(
                                    hasFailedPendingChanges ? "Resolve Sync Issues" : "Pending Changes",
                                    systemImage: hasFailedPendingChanges ? "exclamationmark.triangle.fill" : "clock"
                                )
                            }
                        }
                    }

                    Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                        appState.saveSettings()
                        Task {
                            await syncCoordinator.sync(modelContext: modelContext, appState: appState)
                        }
                    }
                    .disabled(syncCoordinator.isSyncing)

                    Button("Full Resync", systemImage: "arrow.clockwise.icloud") {
                        appState.saveSettings()
                        Task {
                            await syncCoordinator.fullSync(modelContext: modelContext, appState: appState)
                        }
                    }
                    .disabled(syncCoordinator.isSyncing)

                    NavigationLink {
                        SyncActivityView()
                    } label: {
                        Label("Sync Activity", systemImage: "clock.arrow.circlepath")
                    }
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var statusColor: Color {
        if case .failed = appState.syncStatus {
            return .red
        }

        return .secondary
    }

    private var hasFailedPendingChanges: Bool {
        pendingChanges.contains { $0.isFailed }
    }

    private var registerDeviceTitle: String {
        appState.registeredAt == nil ? "Register Device" : "Re-register Device"
    }

    private var registrationStateColor: Color {
        if appState.registeredAt != nil {
            return .green
        }

        if appState.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .red
        }

        return .secondary
    }

    private var registrationStateSymbolName: String {
        if appState.registeredAt != nil {
            return "checkmark.seal.fill"
        }

        if appState.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "exclamationmark.triangle.fill"
        }

        return "iphone.gen3.radiowaves.left.and.right"
    }

    private var tokenStateColor: Color {
        appState.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .red : .secondary
    }

    private var tokenStateSymbolName: String {
        appState.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "key.slash" : "key"
    }

    private func checkServerHealth() async {
        appState.saveSettings()

        guard let baseURL = appState.serverURL else {
            healthCheckState = .failed("Enter a server URL.")
            return
        }

        healthCheckState = .checking

        do {
            let healthURL = baseURL.appending(path: "healthz")
            let (_, response) = try await URLSession.shared.data(from: healthURL)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ServerHealthError.invalidResponse
            }

            guard (200..<300).contains(httpResponse.statusCode) else {
                throw ServerHealthError.httpStatus(httpResponse.statusCode)
            }

            healthCheckState = .healthy(.now)
        } catch {
            healthCheckState = .failed(error.localizedDescription)
        }
    }
}

private enum HealthCheckState: Equatable {
    case idle
    case checking
    case healthy(Date)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "Not checked"
        case .checking:
            return "Checking"
        case .healthy(let date):
            return "OK \(date.formatted(date: .omitted, time: .shortened))"
        case .failed(let message):
            return message
        }
    }

    var symbolName: String {
        switch self {
        case .idle:
            return "circle"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .healthy:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .healthy:
            return .green
        case .failed:
            return .red
        default:
            return .secondary
        }
    }
}

private enum ServerHealthError: LocalizedError {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Server returned an invalid response."
        case .httpStatus(let statusCode):
            return "Server returned HTTP \(statusCode)."
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
        .modelContainer(PreviewData.container)
}
