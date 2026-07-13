import Foundation
import Security

struct ServerConfiguration: Equatable, Sendable {
    let baseURL: URL
    let token: String
}

protocol IngestTokenStore: Sendable {
    func load() throws -> String?
    func save(_ token: String) throws
    func delete() throws
}

enum ServerConfigurationError: Error, Equatable {
    case invalidURL
    case tokenRequired
    case keychain(OSStatus)
}

final class KeychainIngestTokenStore: IngestTokenStore, @unchecked Sendable {
    private let service: String
    private let account = "ingest-token"

    init(service: String = "com.jakobevangelista.runsync.server") {
        self.service = service
    }

    func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ServerConfigurationError.keychain(status) }
        guard let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func save(_ token: String) throws {
        let data = Data(token.utf8)
        var attributes = baseQuery
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                [kSecValueData as String: data,
                 kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary
            )
            guard updateStatus == errSecSuccess else { throw ServerConfigurationError.keychain(updateStatus) }
        } else if status != errSecSuccess {
            throw ServerConfigurationError.keychain(status)
        }
    }

    func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ServerConfigurationError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

actor ServerConfigurationStore {
    private static let baseURLKey = "RunSyncServerBaseURL"
    private let defaults: UserDefaults
    private let tokenStore: any IngestTokenStore
    private let allowInsecureForTesting: Bool

    init(
        defaults: UserDefaults = .standard,
        tokenStore: any IngestTokenStore = KeychainIngestTokenStore(),
        allowInsecureForTesting: Bool = false
    ) {
        self.defaults = defaults
        self.tokenStore = tokenStore
        self.allowInsecureForTesting = allowInsecureForTesting
    }

    func current() throws -> ServerConfiguration? {
        guard let value = defaults.string(forKey: Self.baseURLKey), !value.isEmpty else { return nil }
        let url = try validatedURL(value)
        guard let token = try tokenStore.load(), !token.isEmpty else { return nil }
        return ServerConfiguration(baseURL: url, token: token)
    }

    func displayState() -> (baseURL: String, tokenConfigured: Bool) {
        let url = defaults.string(forKey: Self.baseURLKey) ?? ""
        return (url, (try? tokenStore.load())?.isEmpty == false)
    }

    func save(baseURL: String, token: String?) throws {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            defaults.removeObject(forKey: Self.baseURLKey)
            try tokenStore.delete()
            return
        }
        let url = try validatedURL(trimmedURL)
        let existingToken = try tokenStore.load()
        if let token {
            let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedToken.isEmpty else { throw ServerConfigurationError.tokenRequired }
            try tokenStore.save(trimmedToken)
        } else if existingToken?.isEmpty != false {
            throw ServerConfigurationError.tokenRequired
        }
        defaults.set(url.absoluteString, forKey: Self.baseURLKey)
    }

    private func validatedURL(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let url = components.url else { throw ServerConfigurationError.invalidURL }
        let isLocalhost = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && (isLocalhost || allowInsecureForTesting)) else {
            throw ServerConfigurationError.invalidURL
        }
        return url
    }
}
