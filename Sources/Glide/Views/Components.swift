import AppKit
import SwiftUI

/// A titled slider with its current value on the right and an optional caption.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?
    let format: (Double) -> String
    var minLabel: String?
    var maxLabel: String?
    var caption: String?
    var onEditingEnded: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            slider.labelsHidden()
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }

    /// A slider without tick marks; values still snap to `step`.
    private var slider: some View {
        let snapped = Binding<Double> {
            value
        } set: { newValue in
            guard let step else { value = newValue; return }
            let lower = range.lowerBound
            value = min(max(lower + ((newValue - lower) / step).rounded() * step, lower), range.upperBound)
        }
        return Slider(value: snapped, in: range) {
            Text(title)
        } minimumValueLabel: {
            endLabel(minLabel)
        } maximumValueLabel: {
            endLabel(maxLabel)
        } onEditingChanged: { editing in
            if !editing { onEditingEnded?() }
        }
    }

    private func endLabel(_ text: String?) -> some View {
        Text(text ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// Section footer text, aligned with the section's content.
struct Footnote: View {
    let text: String
    var color: Color = .secondary

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row with a title, a caption underneath and a control on the right.
struct CaptionedRow<Control: View>: View {
    let title: String
    var caption: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            control()
        }
    }
}

/// Picks what a button or gesture does.
struct ActionPicker: View {
    let title: String
    var caption: String?
    @Binding var binding: ActionBinding
    var defaultTitle = "Default"
    var exclude: Set<MouseAction> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CaptionedRow(title: title, caption: caption) {
                Picker(title, selection: $binding.action) {
                    ForEach(ActionGroup.allCases) { group in
                        let actions = MouseAction.allCases.filter { $0.group == group && !exclude.contains($0) }
                        if !actions.isEmpty {
                            Section(group.rawValue) {
                                ForEach(actions) { action in
                                    Label(action == .passthrough ? defaultTitle : action.title, systemImage: action.symbol)
                                        .tag(action)
                                }
                            }
                        }
                    }
                }
                .labelsHidden()
                .fixedSize()
                .frame(width: 270, alignment: .trailing)
            }
            if binding.action == .customShortcut {
                HStack {
                    Spacer()
                    ShortcutRecorder(combo: $binding.shortcut)
                }
            }
        }
    }
}

/// Records a keyboard shortcut. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : startRecording()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: recording ? "record.circle" : "keyboard")
                    .foregroundStyle(recording ? .red : .secondary)
                Text(recording ? "Type the shortcut…" : (combo?.display ?? "Click to record a shortcut"))
                    .monospaced(combo != nil && !recording)
            }
            .frame(minWidth: 200)
        }
        .onDisappear { stop() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .shift, .option, .control, .function])
            if event.keyCode == 53, mods.isEmpty { // Esc
                stop()
                return nil
            }
            combo = KeyCombo(keyCode: event.keyCode, modifiers: UInt64(mods.rawValue), keyLabel: Self.label(for: event))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static let specialKeys: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
    ]

    static func label(for event: NSEvent) -> String {
        if let special = specialKeys[event.keyCode] { return special }
        return (event.charactersIgnoringModifiers ?? "?").uppercased()
    }
}

struct BatteryLabel: View {
    let percent: Int
    let charging: Bool

    var body: some View {
        Label("\(percent)%", systemImage: symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(percent <= 15 && !charging ? .red : .primary)
    }

    private var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

/// Explains a missing permission, with a button straight to the right System Settings page.
struct PermissionCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Glide needs your permission", systemImage: "hand.raised.fill")
                .font(.headline)
            if !model.accessibilityGranted {
                permissionRow(title: "Accessibility",
                              detail: "Needed to smooth the scroll wheel and remap buttons. Turn on Glide in the list.",
                              pane: "Privacy_Accessibility")
            }
            if model.hidStatus == .needsInputMonitoring {
                permissionRow(title: "Input Monitoring",
                              detail: "Needed to talk to the mouse itself (DPI, wheel mode, battery, gesture button).",
                              pane: "Privacy_ListenEvent")
            }
            Text("Glide picks the change up within a second. You don't need to restart it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.orange.opacity(0.35)))
    }

    private func permissionRow(title: String, detail: String, pane: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open Settings") { model.openPrivacyPane(pane) }
        }
    }
}

/// A list and a sideways strip to try the settings on straight away.
struct ScrollTestArea: View {
    private static let words = ["Smooth", "Glide", "Ratchet", "Notch", "Flick", "Scroll", "Wheel", "Momentum", "Precise", "Steady"]

    var body: some View {
        VStack(spacing: 10) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<400, id: \.self) { i in
                        HStack(spacing: 16) {
                            Text(verbatim: "\(i + 1)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                            Text(Self.words[i % Self.words.count])
                            Spacer()
                        }
                        .frame(height: 28)
                        .padding(.horizontal, 12)
                        .background(i % 2 == 0 ? Color.primary.opacity(0.05) : .clear)
                    }
                }
            }
            .frame(height: 200)
            .modifier(TestAreaFrame())

            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(0..<120, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(hue: Double(i % 24) / 24, saturation: 0.45, brightness: 0.85))
                            .frame(width: 54, height: 40)
                            .overlay(Text(verbatim: "\(i + 1)").font(.caption.monospacedDigit()).foregroundStyle(.black.opacity(0.6)))
                    }
                }
                .padding(8)
            }
            .frame(height: 56)
            .modifier(TestAreaFrame())

            Text("Scroll the list with the wheel, and the coloured strip with the thumb wheel or Shift + wheel.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct TestAreaFrame: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }
}
