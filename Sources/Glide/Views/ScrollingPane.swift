import AppKit
import SwiftUI

/// Ready-made scroll feels.
enum ScrollPreset: String, CaseIterable, Identifiable {
    case classic, smooth, silky

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .smooth: "Smooth"
        case .silky: "Silky"
        }
    }

    var values: (lines: Double, smoothness: Double, acceleration: Double) {
        switch self {
        case .classic: (3, 0.07, 0)
        case .smooth: (3, 0.11, 0.25)
        case .silky: (3.5, 0.16, 0.45)
        }
    }

    static func matching(_ s: AppSettings) -> ScrollPreset? {
        allCases.first {
            let v = $0.values
            return s.smoothScrolling && abs(s.linesPerClick - v.lines) < 0.01 && abs(s.smoothness - v.smoothness) < 0.001 && abs(s.acceleration - v.acceleration) < 0.001
        }
    }
}

struct ScrollingPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $model.settings.smoothScrolling) {
                    Text("Smooth scrolling")
                    Text("Each wheel click glides instead of jumping. Off: each click jumps the same distance at once.")
                }
                Picker("Feel", selection: presetBinding) {
                    ForEach(ScrollPreset.allCases) { Text($0.title).tag(Optional($0)) }
                    if ScrollPreset.matching(model.settings) == nil { Text("Custom").tag(ScrollPreset?.none) }
                }
                .pickerStyle(.segmented)
                .disabled(!model.settings.smoothScrolling)
            }

            Section("Vertical") {
                SliderRow(title: "Distance per click", value: $model.settings.linesPerClick, range: 1...10, step: 0.5,
                          format: { "\($0.formatted(.number.precision(.fractionLength(0...1)))) lines · \(Int(($0 * AppSettings.pointsPerLine).rounded())) pt" },
                          minLabel: "Short", maxLabel: "Long",
                          caption: "A typical Windows wheel scrolls 3 lines per click.")
                SliderRow(title: "Smoothness", value: $model.settings.smoothness, range: 0.03...0.25,
                          format: { "\(Int(($0 * 1000).rounded())) ms" },
                          minLabel: "Crisp", maxLabel: "Floaty",
                          caption: "How long each click glides. Lower feels more direct, higher feels softer.")
                    .disabled(!model.settings.smoothScrolling)
                SliderRow(title: "Acceleration", value: $model.settings.acceleration, range: 0...1,
                          format: { $0 < 0.01 ? "Off" : "\(Int(($0 * 100).rounded()))%" },
                          minLabel: "Off", maxLabel: "Strong",
                          caption: "Off means every click scrolls the same distance, however fast you spin. Higher values travel further on fast spins.")
                Toggle("Reverse scroll direction (this mouse only)", isOn: $model.settings.reverseVertical)
            }

            Section("Sideways (thumb wheel)") {
                Picker("Thumb wheel", selection: $model.settings.thumbWheelAction) {
                    ForEach(ThumbWheelAction.allCases) { Text($0.title).tag($0) }
                }
                if model.settings.thumbWheelAction == .horizontalScroll {
                    SliderRow(title: "Distance per click", value: $model.settings.horizontalLinesPerClick, range: 0.5...8, step: 0.5,
                              format: { "\($0.formatted(.number.precision(.fractionLength(0...1)))) lines" },
                              minLabel: "Short", maxLabel: "Long")
                }
                Toggle("Reverse thumb wheel", isOn: $model.settings.reverseHorizontal)
                Toggle("Shift + scroll wheel scrolls sideways", isOn: $model.settings.shiftScrollsHorizontally)
            }

            Section("Try it") {
                ScrollTestArea()
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            }

            Section {
                Toggle(isOn: $model.settings.modifierPassthrough) {
                    Text("Leave ⌘, ⌥ and ⌃ + scroll untouched")
                    Text("Keeps zoom shortcuts such as ⌃ + scroll (screen zoom) and ⌘ + scroll working exactly as before.")
                }
                Toggle(isOn: $model.settings.skipGames) {
                    Text("Don't smooth the wheel in games")
                    Text("Games treat each wheel event as one step, such as the next hotbar slot. Glide detects games and Steam, Unity and Minecraft apps.")
                }
                ExcludedAppsEditor()
            } header: {
                Text("Exceptions")
            }
        }
        .formStyle(.grouped)
    }

    private var presetBinding: Binding<ScrollPreset?> {
        Binding {
            ScrollPreset.matching(model.settings)
        } set: { preset in
            guard let preset else { return }
            let v = preset.values
            model.settings.linesPerClick = v.lines
            model.settings.smoothness = v.smoothness
            model.settings.acceleration = v.acceleration
        }
    }
}

/// Apps where Glide leaves the wheel completely alone.
struct ExcludedAppsEditor: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Other apps to leave alone")
                    Text("Glide won't touch the scroll wheel while one of these is in front.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add App…", action: addApp)
            }
            ForEach(model.settings.excludedApps, id: \.self) { id in
                HStack(spacing: 8) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .frame(width: 18, height: 18)
                        Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                    } else {
                        Image(systemName: "app.dashed")
                        Text(id)
                    }
                    Spacer()
                    Button {
                        model.settings.excludedApps.removeAll { $0 == id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !model.settings.excludedApps.contains(id) {
                model.settings.excludedApps.append(id)
            }
        }
    }
}
