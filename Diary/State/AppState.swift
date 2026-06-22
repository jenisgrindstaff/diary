import Foundation
import LocalAuthentication
import Observation
#if os(iOS)
import UIKit
#endif

@MainActor
@Observable
final class AppState {
    static let localDevelopmentServerURL = "http://127.0.0.1:18080"
    static let localDevelopmentSetupToken = "local-dev-token"

    var serverURLString: String
    var accessToken: String
    var deviceID: String
    var registeredAt: Date?
    var registeredDeviceName: String
    var syncStatus: SyncStatus = .idle

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: KeychainStore

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        self.serverURLString = defaults.string(forKey: DefaultsKey.serverURL) ?? ""
        self.deviceID = defaults.string(forKey: DefaultsKey.deviceID) ?? UIDeviceIdentifier.current
        self.accessToken = keychain.read(account: DefaultsKey.accessToken)
        self.registeredAt = defaults.object(forKey: DefaultsKey.registeredAt) as? Date
        self.registeredDeviceName = defaults.string(forKey: DefaultsKey.registeredDeviceName) ?? ""

        defaults.set(self.deviceID, forKey: DefaultsKey.deviceID)
    }

    var serverURL: URL? {
        guard !serverURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        var value = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.hasPrefix("https://") && !value.hasPrefix("http://") {
            value = "https://\(value)"
        }

        return URL(string: value)
    }

    func saveSettings() {
        defaults.set(serverURLString.trimmingCharacters(in: .whitespacesAndNewlines), forKey: DefaultsKey.serverURL)
        defaults.set(deviceID, forKey: DefaultsKey.deviceID)

        if accessToken.isEmpty {
            keychain.delete(account: DefaultsKey.accessToken)
        } else {
            keychain.save(accessToken, account: DefaultsKey.accessToken)
        }

        if let registeredAt {
            defaults.set(registeredAt, forKey: DefaultsKey.registeredAt)
        } else {
            defaults.removeObject(forKey: DefaultsKey.registeredAt)
        }

        if registeredDeviceName.isEmpty {
            defaults.removeObject(forKey: DefaultsKey.registeredDeviceName)
        } else {
            defaults.set(registeredDeviceName, forKey: DefaultsKey.registeredDeviceName)
        }
    }

    func configureLocalDevelopmentServer() {
        serverURLString = Self.localDevelopmentServerURL
        accessToken = Self.localDevelopmentSetupToken
        registeredAt = nil
        registeredDeviceName = ""
        syncStatus = .idle
        saveSettings()
    }

    func markDeviceRegistered(_ response: RegisterDeviceResponse) {
        accessToken = response.deviceToken
        registeredAt = response.device.registeredAt
        registeredDeviceName = response.device.displayName
        saveSettings()
    }

    var tokenStateLabel: String {
        let trimmedToken = accessToken.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedToken.isEmpty {
            return "Missing"
        }

        if trimmedToken == Self.localDevelopmentSetupToken {
            return "Setup token"
        }

        return "Device token saved"
    }

    var registrationStateLabel: String {
        if let registeredAt {
            return "Registered \(registeredAt.formatted(date: .abbreviated, time: .shortened))"
        }

        if accessToken.trimmingCharacters(in: .whitespacesAndNewlines) == Self.localDevelopmentSetupToken {
            return "Ready to register"
        }

        if !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Token saved"
        }

        return "Not configured"
    }
}

/// Controls the optional Face ID / Touch ID / passcode lock that gates access
/// to the offline diary cache. The enabled flag is persisted; the locked state
/// is transient and re-engaged whenever the app leaves the foreground.
@MainActor
@Observable
final class AppLock {
    /// Whether the lock feature is turned on (persisted across launches).
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: DefaultsKey.appLockEnabled)
            // Turning the lock off must release any active lock immediately.
            // Turning it on engages from the next background/launch rather than
            // interrupting the current session.
            if !isEnabled {
                isLocked = false
                lastError = nil
            }
        }
    }

    /// Whether the app is currently locked and its contents must be hidden.
    private(set) var isLocked: Bool
    private(set) var lastError: String?
    private var isAuthenticating = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let contextProvider: () -> LAContext

    init(defaults: UserDefaults = .standard, contextProvider: @escaping () -> LAContext = { LAContext() }) {
        self.defaults = defaults
        self.contextProvider = contextProvider
        let enabled = defaults.bool(forKey: DefaultsKey.appLockEnabled)
        self.isEnabled = enabled
        // Start locked when the feature is on so content never flashes before
        // the first authentication.
        self.isLocked = enabled
    }

    /// Re-engages the lock when the app leaves the foreground.
    func lock() {
        if isEnabled {
            isLocked = true
        }
    }

    /// Prompts for biometrics (with automatic passcode fallback) and unlocks on
    /// success. A no-op if already unlocked or a prompt is in flight.
    func authenticate(reason: String = "Unlock your diary") async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = contextProvider()
        context.localizedFallbackTitle = "Enter Passcode"
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            if success {
                isLocked = false
                lastError = nil
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The enrolled biometry type, used to label the unlock affordance.
    var biometryType: LABiometryType {
        let context = contextProvider()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    var unlockSymbolName: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        default: return "lock.open"
        }
    }

    var settingsLabel: String {
        switch biometryType {
        case .faceID: return "Require Face ID"
        case .touchID: return "Require Touch ID"
        default: return "Require Passcode"
        }
    }
}

enum SyncStatus: Equatable {
    case idle
    case syncing
    case synced(Date)
    case failed(String)

    var label: String {
        switch self {
        case .idle:
            return "Not synced"
        case .syncing:
            return "Syncing"
        case .synced(let date):
            return "Synced \(date.formatted(date: .omitted, time: .shortened))"
        case .failed(let message):
            return message
        }
    }

    var symbolName: String {
        switch self {
        case .idle:
            return "circle"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .synced:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}

private enum DefaultsKey {
    static let serverURL = "serverURL"
    static let accessToken = "accessToken"
    static let deviceID = "deviceID"
    static let registeredAt = "registeredAt"
    static let registeredDeviceName = "registeredDeviceName"
    static let appLockEnabled = "appLockEnabled"
}

private enum UIDeviceIdentifier {
    static var current: String {
        #if os(iOS)
        if let identifier = UIDevice.current.identifierForVendor?.uuidString {
            return identifier
        }
        #endif

        return UUID().uuidString
    }
}
