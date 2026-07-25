import SwiftUI

struct StatusView: View {
    @ObservedObject var model: AppModel
    let garmin: GarminConnectionService
    @State private var ingestToken = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    statusGrid
                    instructions
                    controls
                    serverConfiguration
                    diagnostics
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("RunSync")
        }
    }

    private var header: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let freshness = WatchReceiptFreshness.evaluate(
                captureEnabled: model.captureEnabled,
                lastReceiptAt: model.lastSampleAt,
                now: context.date
            )
            HStack(alignment: .center, spacing: 14) {
                Circle()
                    .fill(freshnessColor(freshness))
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(freshness.title)
                        .font(.headline)
                    Text(freshness.ageLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.activityStatus.uppercased())
                    .font(.caption.bold())
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.thinMaterial, in: Capsule())
            }
            .padding(18)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        }
    }

    private var statusGrid: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let freshness = WatchReceiptFreshness.evaluate(
                captureEnabled: model.captureEnabled,
                lastReceiptAt: model.lastSampleAt,
                now: context.date
            )
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                statusCell("Authorization", model.authorizationStatus)
                statusCell("Watch", model.watchStatus)
                statusCell("Data field", model.fieldStatus)
                statusCell("Capture", model.captureEnabled ? "Enabled" : "Disabled")
                statusCell("Garmin activity", model.activityStatus)
                statusCell("RunSync session", model.runSyncSessionStatus)
                statusCell("Current activity", abbreviatedRunID)
                statusCell("Watch receipt", freshness.statusLabel)
                statusCell("Watch build", model.watchBuildID ?? "Unknown")
                statusCell("Watch transport", model.watchTransportLastOutcome?.label ?? "Unknown")
                statusCell("Transport failures", transportFailureText)
                statusCell("Local archive", model.archiveStatus)
                statusCell("Archive append", relativeDate(model.lastArchiveAt))
                statusCell("Connectivity", model.connectivityStatus)
                statusCell("Upload", model.serverStatus)
                statusCell("Received", "\(model.receivedCount)")
                statusCell("Pending upload", pendingUploadText)
                statusCell("Last attempt", relativeDate(model.lastUploadAt))
                statusCell("Last acknowledgement", relativeDate(model.lastAcknowledgementAt))
                if model.localArchiveIssueCount > 0 {
                    statusCell("Archive issues", "\(model.localArchiveIssueCount) blocking record(s)")
                }
                if model.quarantineCount > 0 {
                    statusCell("Quarantine", quarantineText)
                }
            }
        }
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Before a run").font(.headline)
            Text("1. Authorize the Forerunner below.")
            Text("2. Add RunSync to a Garmin Run data screen.")
            Text("3. Wait for samples, then start the activity.")
            Text("4. Lock the phone normally. Do not force-quit RunSync.")
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var controls: some View {
        VStack(spacing: 12) {
            Button("Recover & Retry") {
                Task { _ = await garmin.recoverAndRetry() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.recoveryInProgress)
            .frame(maxWidth: .infinity)

            if let recoveryResult = model.recoveryResult {
                Text(recoveryText(recoveryResult))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Toggle("Store live activity and location", isOn: Binding(
                get: { model.captureEnabled },
                set: { garmin.setCaptureEnabled($0) }
            ))

            Text("Telemetry includes precise location and is retained on this iPhone until you delete it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !model.authorizedDevices.isEmpty {
                Picker("Capture watch", selection: Binding(
                    get: { model.selectedCaptureDeviceID },
                    set: { deviceID in
                        if let deviceID { garmin.selectCaptureDevice(deviceID) }
                    }
                )) {
                    Text("Select a watch").tag(Optional<UUID>.none)
                    ForEach(model.authorizedDevices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .pickerStyle(.menu)
            }

            Button("Authorize Garmin Watch") { garmin.authorizeDevice() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

            Button("Delete All Local Telemetry", role: .destructive) {
                garmin.deleteAllTelemetry()
            }
            .frame(maxWidth: .infinity)

        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var serverConfiguration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Telemetry server").font(.headline)
            TextField("https://runsync-api.example.com", text: $model.serverBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textFieldStyle(.roundedBorder)
            SecureField(model.serverTokenConfigured ? "Token saved (leave blank to keep)" : "Ingest token", text: $ingestToken)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Save") {
                    garmin.saveServerConfiguration(baseURL: model.serverBaseURL, token: ingestToken)
                    ingestToken = ""
                }
                .buttonStyle(.borderedProminent)
                Button("Retry now") { garmin.retryUploads(force: true) }
                    .buttonStyle(.bordered)
                Button("Remove", role: .destructive) {
                    model.serverBaseURL = ""
                    ingestToken = ""
                    garmin.saveServerConfiguration(baseURL: "", token: "")
                }
                .buttonStyle(.bordered)
            }
            if model.quarantineCount > 0 {
                Button("Retry quarantined envelopes") { garmin.retryQuarantinedEnvelopes() }
                    .buttonStyle(.bordered)
            }
            if !model.serverConfigurationStatus.isEmpty {
                Text(model.serverConfigurationStatus).font(.caption).foregroundStyle(.secondary)
            }
            Text("Last attempt: \(relativeDate(model.lastUploadAt)). Credentials and location are never written to diagnostics.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics").font(.headline)
            if model.diagnosticEvents.isEmpty {
                Text("No events yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.diagnosticEvents.prefix(10).enumerated()), id: \.offset) { _, event in
                    Text(event)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
    }

    private func statusCell(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .padding(14)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var abbreviatedRunID: String {
        model.currentRunID.map { String($0.uuidString.prefix(8)) } ?? "None"
    }

    private var pendingUploadText: String {
        guard let age = model.oldestPendingAge, model.pendingUploadCount > 0 else {
            return "\(model.pendingUploadCount)"
        }
        return "\(model.pendingUploadCount), oldest \(Int(age))s"
    }

    private var quarantineText: String {
        let identifier = model.lastQuarantinedEnvelopeID.map { String($0.uuidString.prefix(8)) } ?? "unknown"
        let category = model.lastQuarantineCategory ?? "rejected_envelope"
        return "\(model.quarantineCount), last \(identifier) (\(category))"
    }

    private var transportFailureText: String {
        let failures = model.watchTransportConsecutiveFailures.map(String.init) ?? "Unknown"
        let timeouts = model.watchTransportTimeoutCount.map(String.init) ?? "Unknown"
        return "F \(failures), T \(timeouts)"
    }

    private func recoveryText(_ result: GarminRecoveryResult) -> String {
        let capture = result.captureResumed ? "Capture resumed" : "Capture remains paused"
        let pending = "\(result.pendingEnvelopeCount) pending"
        return "\(capture). \(pending). Upload: \(result.uploadState.label)."
    }

    private func relativeDate(_ date: Date?) -> String {
        guard let date else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func freshnessColor(_ freshness: WatchReceiptFreshness) -> Color {
        switch freshness {
        case .captureDisabled: .gray
        case .never: .orange
        case .current: .green
        case .delayed: .yellow
        case .unavailable: .red
        }
    }
}
