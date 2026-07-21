import XCTest
@testable import RunSync

final class ServerConfigurationTests: XCTestCase {
    func testStoresURLInDefaultsAndTokenOnlyInSecretStore() async throws {
        let suite = "ServerConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = TestTokenStore()
        let store = ServerConfigurationStore(defaults: defaults, tokenStore: tokens)

        try await store.save(baseURL: "https://runsync.example.com", token: "top-secret")
        let configuration = try await store.current()
        XCTAssertEqual(configuration?.baseURL.absoluteString, "https://runsync.example.com")
        XCTAssertEqual(configuration?.token, "top-secret")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "top-secret" })
    }

    func testRequiresTokenAndRejectsInvalidScheme() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = ServerConfigurationStore(defaults: defaults, tokenStore: TestTokenStore())
        do {
            try await store.save(baseURL: "https://runsync.example.com", token: nil)
            XCTFail("Expected token requirement")
        } catch let error as ServerConfigurationError {
            XCTAssertEqual(error, .tokenRequired)
        }
        do {
            try await store.save(baseURL: "ftp://runsync.example.com", token: "token")
            XCTFail("Expected invalid URL")
        } catch let error as ServerConfigurationError {
            XCTAssertEqual(error, .invalidURL)
        }
        do {
            try await store.save(baseURL: "http://runsync.example.com", token: "token")
            XCTFail("Expected HTTPS requirement")
        } catch let error as ServerConfigurationError {
            XCTAssertEqual(error, .invalidURL)
        }
    }

    func testClearingURLAlsoDeletesToken() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let tokens = TestTokenStore()
        let store = ServerConfigurationStore(defaults: defaults, tokenStore: tokens)
        try await store.save(baseURL: "https://runsync.example.com", token: "top-secret")

        try await store.save(baseURL: "", token: nil)

        let state = await store.displayState()
        XCTAssertEqual(state.baseURL, "")
        XCTAssertFalse(state.tokenConfigured)
        let current = try await store.current()
        XCTAssertNil(current)
    }

    func testKeychainFailuresFailClosedAndAdvanceRevisionDuringRecovery() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let tokens = FailingConfigurationTokenStore()
        let store = ServerConfigurationStore(defaults: defaults, tokenStore: tokens)
        try await store.save(baseURL: "https://old.example", token: "old-token")
        let before = try await store.snapshot()

        tokens.failSaves = true
        do {
            try await store.save(baseURL: "https://new.example", token: "new-token")
            XCTFail("Expected Keychain save failure")
        } catch {}
        tokens.failSaves = false
        let afterFailedSave = try await store.snapshot()
        XCTAssertNil(afterFailedSave.configuration)
        XCTAssertEqual(afterFailedSave.revision, before.revision + 1)

        try await store.save(baseURL: "https://old.example", token: "old-token")
        let beforeClear = try await store.snapshot()
        tokens.failDeletes = true
        do {
            try await store.save(baseURL: "", token: nil)
            XCTFail("Expected Keychain delete failure")
        } catch {}
        do {
            _ = try await store.snapshot()
            XCTFail("Incomplete clear must remain unavailable while Keychain is locked")
        } catch {}
        tokens.failDeletes = false
        let afterFailedClear = try await store.snapshot()
        XCTAssertNil(afterFailedClear.configuration)
        XCTAssertEqual(afterFailedClear.revision, beforeClear.revision + 1)
    }

    func testInterruptedCrossStoreUpdatesRecoverToDisabledConfiguration() async throws {
        let suite = "ServerConfigurationCrashTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tokens = TestTokenStore()
        var store = ServerConfigurationStore(defaults: defaults, tokenStore: tokens)
        try await store.save(baseURL: "https://old.example", token: "old-token")
        let beforeTokenFirstCrash = try await store.snapshot()

        defaults.set(true, forKey: ServerConfigurationStore.updateInProgressKey)
        defaults.synchronize()
        try tokens.save("new-token")
        store = ServerConfigurationStore(defaults: defaults, tokenStore: tokens)
        let afterTokenFirstCrash = try await store.snapshot()

        XCTAssertNil(afterTokenFirstCrash.configuration)
        XCTAssertEqual(afterTokenFirstCrash.revision, beforeTokenFirstCrash.revision + 1)
        XCTAssertNil(try tokens.load())
        XCTAssertFalse(defaults.bool(forKey: ServerConfigurationStore.updateInProgressKey))

        try await store.save(baseURL: "https://old.example", token: "old-token")
        let beforeURLFirstCrash = try await store.snapshot()
        defaults.set(true, forKey: ServerConfigurationStore.updateInProgressKey)
        defaults.set("https://new.example", forKey: "RunSyncServerBaseURL")
        defaults.synchronize()
        store = ServerConfigurationStore(defaults: defaults, tokenStore: tokens)
        let afterURLFirstCrash = try await store.snapshot()

        XCTAssertNil(afterURLFirstCrash.configuration)
        XCTAssertEqual(afterURLFirstCrash.revision, beforeURLFirstCrash.revision + 1)
        XCTAssertNil(try tokens.load())
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains {
            ($0 as? String) == "old-token" || ($0 as? String) == "new-token"
        })
    }
}

private final class FailingConfigurationTokenStore: IngestTokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    var failSaves = false
    var failDeletes = false

    func load() -> String? { lock.withLock { token } }

    func save(_ token: String) throws {
        try lock.withLock {
            if failSaves { throw ServerConfigurationError.keychain(-25308) }
            self.token = token
        }
    }

    func delete() throws {
        try lock.withLock {
            if failDeletes { throw ServerConfigurationError.keychain(-25308) }
            token = nil
        }
    }
}
