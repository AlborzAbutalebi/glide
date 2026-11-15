import AppKit
import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let symbol = model.settings.enabled ? "computermouse.fill" : "computermouse"
        Group {
            if model.settings.showBatteryInMenuBar, let battery = model.mouse?.battery {
                Label("\(battery)%", systemImage: symbol)
                    .labelStyle(.titleAndIcon)
            } else {
                Image(systemName: symbol)
            }
        }
        .onAppear { model.openSettingsWindow = { openWindow(id: "settings") } }
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let m = model.mouse {
            Text(m.name + (m.battery.map { " — \($0)%" } ?? "") + (m.charging ? " (charging)" : ""))
        } else {
            Text(model.hidStatus == .needsInputMonitoring ? "Mouse: needs Input Monitoring" : "Looking for your mouse…")
        }
        if model.needsAttention {
            Button("Finish Setting Up Glide…") { showSettings() }
        }
        Divider()

        Toggle("Smooth Scrolling", isOn: $model.settings.smoothScrolling)

        if model.mouse?.supportsSmartShift == true {
            Picker("Scroll Wheel", selection: wheelBinding) {
                ForEach(WheelMode.allCases) { Text($0.title).tag(Optional($0)) }
            }
        }
        if model.mouse?.supportsDPI == true {
            Picker("Pointer Speed", selection: dpiBinding) {
                ForEach(dpiChoices, id: \.self) { Text("\($0) DPI").tag(Optional($0)) }
            }
        }
        Divider()

        Toggle("Glide On", isOn: $model.settings.enabled)
        Button("Settings…") { showSettings() }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Glide") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var wheelBinding: Binding<WheelMode?> {
        Binding { model.effectiveWheelMode } set: { if let mode = $0 { model.setWheelMode(mode) } }
    }

    private var dpiBinding: Binding<Int?> {
        Binding { model.effectiveDPI } set: { if let dpi = $0 { model.settings.dpi = dpi } }
    }

    private var dpiChoices: [Int] {
        Array(Set(model.settings.dpiPresets + [model.effectiveDPI])).sorted()
    }

    private func showSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

}
