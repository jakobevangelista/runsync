import SwiftUI

struct StatusView: View {
    @ObservedObject var model: AppModel
    let garmin: GarminConnectionService

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    statusGrid
                    instructions
                    controls
                    diagnostics
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("RunSync")
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Circle()
                .fill(model.lastSampleAt == nil ? Color.orange : Color.green)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.lastSampleAt == nil ? "Waiting for telemetry" : "Telemetry received")
                    .font(.headline)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(lastSampleText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
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

    private var statusGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            statusCell("Authorization", model.authorizationStatus)
            statusCell("Watch", model.watchStatus)
            statusCell("Data field", model.fieldStatus)
            statusCell("Archive", model.archiveStatus)
            statusCell("Mock ingest", model.mockStatus)
            statusCell("Received", "\(model.receivedCount)")
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
            Toggle("Store live activity and location", isOn: Binding(
                get: { model.captureEnabled },
                set: { garmin.setCaptureEnabled($0) }
            ))

            Text("Telemetry includes precise location and is retained on this iPhone until you delete it.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button("Authorize Garmin Watch") { garmin.authorizeDevice() }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)

            Button("Delete All Local Telemetry", role: .destructive) {
                garmin.deleteAllTelemetry()
            }
            .frame(maxWidth: .infinity)

#if DEBUG
            Toggle("Inject mock ingest failure", isOn: Binding(
                get: { model.mockFailureInjection },
                set: { garmin.setMockFailureInjection($0) }
            ))
#endif
        }
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

    private var lastSampleText: String {
        guard let lastSampleAt else { return "No sample received yet" }
        return "Last sample \(max(0, Int(Date().timeIntervalSince(lastSampleAt))))s ago"
    }

    private var lastSampleAt: Date? { model.lastSampleAt }
}
