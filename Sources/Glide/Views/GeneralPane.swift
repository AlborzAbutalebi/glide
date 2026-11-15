import AppKit
import SwiftUI

struct GeneralPane: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.settings.enabled) {
                    Text("Glide is on")
                    Text("Turn off to hand the wheel and buttons straight back to macOS. Settings stored in the mouse, such as DPI and wheel mode, stay as they are.")
                }
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Toggle("Show battery level in the menu bar", isOn: $model.settings.showBatteryInMenuBar)
            }

            Section("Permissions") {
                permissionRow("Accessibility", granted: model.accessibilityGranted,
                              detail: "Smooth scrolling and button remapping", pane: "Privacy_Accessibility")
                permissionRow("Input Monitoring", granted: model.hidStatus != .needsInputMonitoring,
                              detail: "Talking to the mouse: DPI, wheel mode, battery, gesture button", pane: "Privacy_ListenEvent")
            }

            if let m = model.mouse {
                Section("Mouse") {
                    LabeledContent("Model", value: m.name)
                    LabeledContent("Connection", value: m.transport)
                    if let fw = m.firmware { LabeledContent("Firmware", value: fw) }
                    if let v = m.protocolVersion { LabeledContent("HID++ protocol", value: v) }
                    LabeledContent("Product ID", value: String(format: "0x%04X", m.productID))
                }
            }

            Section {
                HStack {
                    Button("Show Log") { NSWorkspace.shared.open(Log.url) }
                    Button("Show Settings File") { NSWorkspace.shared.activateFileViewerSelecting([AppSettings.fileURL]) }
                    Spacer()
                    Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                }
            } footer: {
                Text("Glide \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all Glide settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { model.resetAll() }
        } message: {
            Text("Scrolling, buttons and pointer settings go back to their defaults. DPI and wheel mode stay as the mouse has them now.")
        }
    }

    private func permissionRow(_ title: String, granted: Bool, detail: String, pane: String) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Open Settings") { model.openPrivacyPane(pane) } }
        }
    }
}
