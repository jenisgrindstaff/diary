import Foundation
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
