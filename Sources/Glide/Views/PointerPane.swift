import SwiftUI

struct PointerPane: View {
    @EnvironmentObject var model: AppModel
    @State private var draggingDPI: Double?
    @State private var presetsText = ""

    private let quickPicks = [400, 800, 1000, 1600, 2400, 3200, 4000]

    var body: some View {
        Form {
            if let m = model.mouse, m.supportsDPI {
                Section {
                    SliderRow(title: "Sensor resolution", value: dpiBinding(m), range: Double(m.dpiMin)...Double(m.dpiMax), step: Double(m.dpiStep),
                              format: { "\(Int($0)) DPI" }, minLabel: "\(m.dpiMin)", maxLabel: "\(m.dpiMax)",
                              caption: "Higher DPI moves the pointer further for the same hand movement. It is set in the mouse, so it works the same in every app.",
                              onEditingEnded: commitDPI)
                    HStack(spacing: 6) {
                        ForEach(quickPicks.filter { $0 >= m.dpiMin && $0 <= m.dpiMax }, id: \.self) { value in
                            Button(String(value)) { model.settings.dpi = value }
                                .buttonStyle(.bordered)
                                .tint(model.effectiveDPI == value ? .accentColor : nil)
                        }
                        Spacer()
                        if let def = m.dpiDefault {
                            Button("Default") { model.settings.dpi = def }
                                .buttonStyle(.borderless)
                        }
                    }
                } header: {
                    Text("Speed (DPI)")
                }
            } else {
                Section("Speed (DPI)") {
                    Label("Connect your Logitech mouse to change its DPI.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("Pointer acceleration", selection: $model.settings.pointerAcceleration) {
                    ForEach(PointerAcceleration.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
            } header: {
                Text("Acceleration")
            } footer: {
                Footnote("With acceleration off, the pointer always travels the same distance for the same hand movement. Many people find that easier to control. This only changes this mouse, not your trackpad.")
            }

            Section {
                TextField("DPI presets", text: $presetsText, prompt: Text("800, 1200, 1600, 2400"))
                    .onSubmit(savePresets)
                    .onAppear { presetsText = model.settings.dpiPresets.map(String.init).joined(separator: ", ") }
            } header: {
                Text("DPI presets")
            } footer: {
                Footnote("Used by the menu bar and by any button set to Cycle DPI presets. Separate values with commas, then press Return.")
            }
        }
        .formStyle(.grouped)
    }

    private func dpiBinding(_ m: MouseState) -> Binding<Double> {
        Binding {
            draggingDPI ?? Double(model.effectiveDPI)
        } set: {
            draggingDPI = $0
        }
    }

    private func commitDPI() {
        if let value = draggingDPI { model.settings.dpi = Int(value) }
        draggingDPI = nil
    }

    private func savePresets() {
        let values = presetsText.split(whereSeparator: { ",; ".contains($0) }).compactMap { Int($0) }
            .filter { $0 >= (model.mouse?.dpiMin ?? 100) && $0 <= (model.mouse?.dpiMax ?? 25600) }
        if !values.isEmpty { model.settings.dpiPresets = Array(Set(values)).sorted() }
        presetsText = model.settings.dpiPresets.map(String.init).joined(separator: ", ")
    }
}
