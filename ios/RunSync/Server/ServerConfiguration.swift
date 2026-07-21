import Foundation
import Security

struct ServerConfiguration: Equatable, Sendable {
    let baseURL: URL
    let token: String
}

struct ServerConfigurationSnapshot: Sendable {
    let configuration: ServerConfiguration?
    let revision: UInt64
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
    case staleRevision
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
    private static let revisionKey = "RunSyncServerConfigurationRevision"
    static let updateInProgressKey = "RunSyncServerConfigurationUpdateInProgress"
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
        try snapshot().configuration
    }

    func snapshot() throws -> ServerConfigurationSnapshot {
        try recoverIncompleteUpdateIfNeeded()
        let revision = currentRevision
        guard let value = defaults.string(forKey: Self.baseURLKey), !value.isEmpty else {
            return ServerConfigurationSnapshot(configuration: nil, revision: revision)
        }
        let url = try validatedURL(value)
        guard let token = try tokenStore.load(), !token.isEmpty else {
            return ServerConfigurationSnapshot(configuration: nil, revision: revision)
        }
        return ServerConfigurationSnapshot(
            configuration: ServerConfiguration(baseURL: url, token: token),
            revision: revision
        )
    }

    func displayState() -> (baseURL: String, tokenConfigured: Bool) {
        do {
            try recoverIncompleteUpdateIfNeeded()
        } catch {
            return ("", false)
        }
        let url = defaults.string(forKey: Self.baseURLKey) ?? ""
        return (url, (try? tokenStore.load())?.isEmpty == false)
    }

    func save(baseURL: String, token: String?) throws {
        try recoverIncompleteUpdateIfNeeded()
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            beginUpdate()
            try tokenStore.delete()
            defaults.removeObject(forKey: Self.baseURLKey)
            advanceRevision()
            finishUpdate()
            return
        }
        let url = try validatedURL(trimmedURL)
        let existingToken = try tokenStore.load()
        let tokenToSave: String?
        if let token {
            let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedToken.isEmpty else { throw ServerConfigurationError.tokenRequired }
            tokenToSave = trimmedToken
        } else if existingToken?.isEmpty != false {
            throw ServerConfigurationError.tokenRequired
        } else {
            tokenToSave = nil
        }
        beginUpdate()
        if let tokenToSave { try tokenStore.save(tokenToSave) }
        defaults.set(url.absoluteString, forKey: Self.baseURLKey)
        advanceRevision()
        finishUpdate()
    }

    func snapshot(atLeastRevision minimumRevision: UInt64) throws -> ServerConfigurationSnapshot {
        let current = try snapshot()
        guard current.revision < minimumRevision else { return current }
        defaults.set(Int64(bitPattern: minimumRevision), forKey: Self.revisionKey)
        return try snapshot()
    }

    private func advanceRevision() {
        defaults.set(Int64(bitPattern: currentRevision &+ 1), forKey: Self.revisionKey)
    }

    private func beginUpdate() {
        defaults.set(true, forKey: Self.updateInProgressKey)
        defaults.synchronize()
    }

    private func finishUpdate() {
        defaults.removeObject(forKey: Self.updateInProgressKey)
        defaults.synchronize()
    }

    private func recoverIncompleteUpdateIfNeeded() throws {
        guard defaults.bool(forKey: Self.updateInProgressKey) else { return }
        try tokenStore.delete()
        defaults.removeObject(forKey: Self.baseURLKey)
        advanceRevision()
        finishUpdate()
    }

    private var currentRevision: UInt64 {
        (defaults.object(forKey: Self.revisionKey) as? NSNumber)?.uint64Value ?? 0
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
