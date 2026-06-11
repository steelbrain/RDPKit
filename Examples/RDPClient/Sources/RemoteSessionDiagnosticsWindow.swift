import SwiftUI

struct RemoteSessionDiagnosticsWindow: View {
    @EnvironmentObject private var launchStore: RDPConnectionLaunchStore

    var sessionID: UUID?

    var body: some View {
        Group {
            if let sessionID,
               let model = launchStore.diagnosticsModel(for: sessionID)
            {
                RemoteSessionDiagnosticsWindowContent(model: model)
            } else {
                ContentUnavailableView(
                    "Stats for Nerds Not Available",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text("Open stats for nerds from an active remote desktop window.")
                )
            }
        }
        .frame(minWidth: 700, minHeight: 560)
    }
}
