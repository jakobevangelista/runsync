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
}
