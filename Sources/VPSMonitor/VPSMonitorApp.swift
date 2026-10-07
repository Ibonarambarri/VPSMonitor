import SwiftUI

@main
struct VPSMonitorApp: App {
    @StateObject private var model = MonitorViewModel()

    var body: some Scene {
        MenuBarExtra {
            MonitorView()
                .environmentObject(model)
        } label: {
            HStack(spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: "server.rack")
                    Circle()
                        .fill(model.overallState.color)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.background, lineWidth: 1))
                        .offset(x: 2, y: 2)
                }
                if model.preferences.showCPUInMenuBar, let metrics = model.selectedMonitor?.metrics {
                    Text(Formatters.percent(metrics.cpuPercent)).monospacedDigit()
                }
            }
            .accessibilityLabel("VPS Monitor: \(model.overallState.accessibilityName)")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
