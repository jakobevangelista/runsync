import CryptoKit
import Foundation

struct TelemetryUploadFence: Codable, Equatable, Sendable {
    let configurationGeneration: UInt64
    let destinationFingerprint: String
    let deleteEpoch: UInt64
}

struct TelemetryUploadBinding: Sendable {
    let server: ServerConfiguration
    let fence: TelemetryUploadFence
}

struct TelemetryUploadControlSnapshot: Equatable, Sendable {
    let fence: TelemetryUploadFence?
    let deleteEpoch: UInt64
    let deletionInProgress: Bool
}

final class TelemetryUploadFenceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var fence: TelemetryUploadFence?
    private var deletionInProgress = false

    func install(_ snapshot: TelemetryUploadControlSnapshot) {
        lock.withLock {
            fence = snapshot.fence
            deletionInProgress = snapshot.deletionInProgress
        }
    }

    func persistAndInstall(
        _ snapshot: TelemetryUploadControlSnapshot,
        persistence: () throws -> Void
    ) throws {
        try lock.withLock {
            try persistence()
            fence = snapshot.fence
            deletionInProgress = snapshot.deletionInProgress
        }
    }

    func isCurrent(_ candidate: TelemetryUploadFence) -> Bool {
        lock.withLock { !deletionInProgress && fence == candidate }
    }

    func withCurrentFence<T>(_ candidate: TelemetryUploadFence, _ operation: () throws -> T) rethrows -> T? {
        try lock.withLock {
            guard !deletionInProgress, fence == candidate else { return nil }
            return try operation()
        }
    }
}

actor TelemetryUploadControlStore {
    enum ControlError: Error, Equatable {
        case deletionEpochMismatch
    }

    private struct State: Codable {
        var configurationGeneration: UInt64
        var destinationFingerprint: String?
        var configurationBinding: String?
        var configurationRevision: UInt64?
        var deleteEpoch: UInt64
        var deletion: Deletion
    }

    private struct Deletion: Codable {
        enum Status: String, Codable { case completed, inProgress }
        var status: Status
        var epoch: UInt64
    }

    struct Synchronization: Sendable {
        let fence: TelemetryUploadFence?
        let changed: Bool
    }

    struct BindingResult: Sendable {
        let binding: TelemetryUploadBinding?
        let changed: Bool
        let stale: Bool
        let requiredRevision: UInt64?
    }

    private let rootURL: URL
    private let stateURL: URL
    private let fileManager: FileManager
    private let gate: TelemetryUploadFenceGate
    private let stateLoader: @Sendable (URL) throws -> Data
    private var state: State
    private var loadError: Error?

    init(
        rootURL: URL? = nil,
        fileManager: FileManager = .default,
        gate: TelemetryUploadFenceGate,
        stateLoader: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) {
        self.fileManager = fileManager
        self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        self.stateURL = self.rootURL.appendingPathComponent("upload-control.json")
        self.gate = gate
        self.stateLoader = stateLoader
        do {
            self.state = try Self.readState(at: self.stateURL, loader: stateLoader)
            self.loadError = nil
        } catch where !fileManager.fileExists(atPath: self.stateURL.path) {
            self.state = State(
                configurationGeneration: 0,
                destinationFingerprint: nil,
                configurationBinding: nil,
                configurationRevision: nil,
                deleteEpoch: 0,
                deletion: Deletion(status: .completed, epoch: 0)
            )
            self.loadError = nil
        } catch {
            self.state = State(
                configurationGeneration: 0,
                destinationFingerprint: nil,
                configurationBinding: nil,
                configurationRevision: nil,
                deleteEpoch: 0,
                deletion: Deletion(status: .inProgress, epoch: 0)
            )
            self.loadError = error
        }
        gate.install(Self.snapshot(for: self.state))
    }

    func synchronize(
        configuration: ServerConfiguration?,
        installationID: UUID
    ) throws -> Synchronization {
        try reloadIfNeeded()
        let fingerprint = configuration.flatMap { try? Self.destinationFingerprint(for: $0.baseURL) }
        let binding = Self.bindingFingerprint(
            destinationFingerprint: fingerprint,
            token: configuration?.token,
            installationID: installationID
        )
        let changed = state.configurationBinding != binding
        if changed {
            var next = state
            next.configurationGeneration &+= 1
            next.configurationBinding = binding
            next.destinationFingerprint = fingerprint
            try persistAndPublish(next)
        }
        return Synchronization(fence: currentFence(), changed: changed)
    }

    func bind(
        configuration: ServerConfiguration?,
        installationID: UUID
    ) throws -> (binding: TelemetryUploadBinding?, changed: Bool) {
        let synchronization = try synchronize(
            configuration: configuration,
            installationID: installationID
        )
        guard let configuration, let fence = synchronization.fence else {
            return (nil, synchronization.changed)
        }
        return (TelemetryUploadBinding(server: configuration, fence: fence), synchronization.changed)
    }

    func bind(
        snapshot: ServerConfigurationSnapshot,
        installationID: UUID
    ) throws -> BindingResult {
        try reloadIfNeeded()
        if let currentRevision = state.configurationRevision,
           snapshot.revision < currentRevision {
            return BindingResult(
                binding: nil,
                changed: false,
                stale: true,
                requiredRevision: currentRevision
            )
        }

        let fingerprint = snapshot.configuration.flatMap {
            try? Self.destinationFingerprint(for: $0.baseURL)
        }
        let bindingFingerprint = Self.bindingFingerprint(
            destinationFingerprint: fingerprint,
            token: snapshot.configuration?.token,
            installationID: installationID
        )
        if state.configurationRevision == snapshot.revision,
           state.configurationBinding != nil,
           state.configurationBinding != bindingFingerprint {
            return BindingResult(
                binding: nil,
                changed: false,
                stale: true,
                requiredRevision: snapshot.revision &+ 1
            )
        }

        let changed = state.configurationBinding != bindingFingerprint
            || state.configurationRevision != snapshot.revision
        if changed {
            var next = state
            next.configurationGeneration &+= 1
            next.configurationBinding = bindingFingerprint
            next.configurationRevision = snapshot.revision
            next.destinationFingerprint = fingerprint
            try persistAndPublish(next)
        }
        guard let configuration = snapshot.configuration, let fence = currentFence() else {
            return BindingResult(
                binding: nil,
                changed: changed,
                stale: false,
                requiredRevision: nil
            )
        }
        return BindingResult(
            binding: TelemetryUploadBinding(server: configuration, fence: fence),
            changed: changed,
            stale: false,
            requiredRevision: nil
        )
    }

    func snapshot() -> TelemetryUploadControlSnapshot {
        Self.snapshot(for: state)
    }

    func persistedSnapshot() throws -> TelemetryUploadControlSnapshot {
        try reloadIfNeeded()
        return Self.snapshot(for: state)
    }

    func isCurrent(_ fence: TelemetryUploadFence) -> Bool {
        loadError == nil && currentFence() == fence && state.deletion.status == .completed
    }

    func beginDeletion() throws -> UInt64 {
        try reloadIfNeeded()
        if state.deletion.status == .inProgress { return state.deletion.epoch }
        var next = state
        next.configurationGeneration &+= 1
        next.deleteEpoch &+= 1
        next.deletion = Deletion(status: .inProgress, epoch: next.deleteEpoch)
        try persistAndPublish(next)
        return state.deleteEpoch
    }

    func completeDeletion(epoch: UInt64) throws {
        try reloadIfNeeded()
        if state.deletion.status == .completed, state.deleteEpoch == epoch { return }
        guard state.deletion.status == .inProgress, state.deletion.epoch == epoch else {
            throw ControlError.deletionEpochMismatch
        }
        var next = state
        next.deletion.status = .completed
        try persistAndPublish(next)
    }

    private func currentFence() -> TelemetryUploadFence? {
        guard state.deletion.status == .completed, let fingerprint = state.destinationFingerprint else { return nil }
        return TelemetryUploadFence(
            configurationGeneration: state.configurationGeneration,
            destinationFingerprint: fingerprint,
            deleteEpoch: state.deleteEpoch
        )
    }

    private func persistAndPublish(_ next: State) throws {
        try gate.persistAndInstall(Self.snapshot(for: next)) {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            let data = try JSONEncoder().encode(next)
            try data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        state = next
    }

    private nonisolated static func snapshot(for state: State) -> TelemetryUploadControlSnapshot {
        let fence = state.deletion.status == .completed ? state.destinationFingerprint.map {
            TelemetryUploadFence(
                configurationGeneration: state.configurationGeneration,
                destinationFingerprint: $0,
                deleteEpoch: state.deleteEpoch
            )
        } : nil
        return TelemetryUploadControlSnapshot(
            fence: fence,
            deleteEpoch: state.deleteEpoch,
            deletionInProgress: state.deletion.status == .inProgress
        )
    }

    private func reloadIfNeeded() throws {
        guard loadError != nil else { return }
        do {
            state = try Self.readState(at: stateURL, loader: stateLoader)
            loadError = nil
            gate.install(Self.snapshot(for: state))
        } catch where !fileManager.fileExists(atPath: stateURL.path) {
            state = State(
                configurationGeneration: 0,
                destinationFingerprint: nil,
                configurationBinding: nil,
                configurationRevision: nil,
                deleteEpoch: 0,
                deletion: Deletion(status: .completed, epoch: 0)
            )
            loadError = nil
            gate.install(Self.snapshot(for: state))
        } catch {
            loadError = error
            throw error
        }
    }

    private nonisolated static func readState(
        at url: URL,
        loader: @Sendable (URL) throws -> Data
    ) throws -> State {
        try JSONDecoder().decode(State.self, from: loader(url))
    }

    nonisolated static func destinationFingerprint(for baseURL: URL) throws -> String {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty else {
            throw ServerConfigurationError.invalidURL
        }
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || (scheme == "http" && isLoopback) else {
            throw ServerConfigurationError.invalidURL
        }
        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.query = nil
        components.fragment = nil
        var path = components.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path
        guard let normalized = components.string else { throw ServerConfigurationError.invalidURL }
        return sha256(normalized)
    }

    private nonisolated static func bindingFingerprint(
        destinationFingerprint: String?,
        token: String?,
        installationID: UUID
    ) -> String {
        sha256("\(destinationFingerprint ?? "unconfigured")\u{0}\(token ?? "")\u{0}\(installationID.uuidString)")
    }

    private nonisolated static func sha256(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func defaultRootURL(fileManager: FileManager) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RunSync", isDirectory: true)
    }
}

enum TelemetryDeletionTransaction {
    static func begin(
        control: TelemetryUploadControlStore,
        queue: BackgroundUploadQueue,
        archive: TelemetryArchive
    ) async throws {
        let epoch = try await control.beginDeletion()
        try await removeTelemetry(queue: queue, archive: archive)
        try await control.completeDeletion(epoch: epoch)
    }

    static func resumeIfNeeded(
        control: TelemetryUploadControlStore,
        queue: BackgroundUploadQueue,
        archive: TelemetryArchive
    ) async throws {
        let snapshot = try await control.persistedSnapshot()
        guard snapshot.deletionInProgress else { return }
        try await removeTelemetry(queue: queue, archive: archive)
        try await control.completeDeletion(epoch: snapshot.deleteEpoch)
    }

    private static func removeTelemetry(
        queue: BackgroundUploadQueue,
        archive: TelemetryArchive
    ) async throws {
        try await queue.removeAll()
        try await archive.deleteAll()
        guard !(await queue.exists()), !(await archive.hasTelemetryFiles()) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
