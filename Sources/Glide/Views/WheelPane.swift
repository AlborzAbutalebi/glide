import Combine
import SwiftUI

struct WheelPane: View {
    @EnvironmentObject var model: AppModel
    private let poll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            if let m = model.mouse, m.supportsSmartShift {
                Section {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(m.freeSpin == true ? Color.blue : Color.green)
                            .frame(width: 10, height: 10)
                        Text(m.freeSpin == true ? "The wheel is spinning free right now" : "The wheel is clicking (ratchet) right now")
                        Spacer()
                        if let clicks = m.ratchetsPerRotation, clicks > 0 {
                            Text("\(clicks) clicks per turn")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    ForEach(WheelMode.allCases) { mode in
                        modeRow(mode, selected: model.effectiveWheelMode == mode)
                    }
                } header: {
                    Text("Wheel mode")
                } footer: {
                    Footnote("This is the physical feel of the wheel, set inside the mouse. The button behind the wheel also switches between clicking and free-spin, unless you give it another job under Buttons.")
                }

                if model.effectiveWheelMode == .smartShift {
                    Section("SmartShift") {
                        SliderRow(title: "Flick speed that frees the wheel", value: thresholdBinding, range: 1...49, step: 1,
                                  format: { "\(Int($0))" }, minLabel: "Gentle flick", maxLabel: "Hard flick",
                                  caption: "Low values let go of the clicks easily. If the wheel drops into free-spin when you don't want it to, move this to the right, or choose Ratchet.")
                        if let def = m.smartShiftDefault {
                            Button("Reset to the mouse's default (\(def))") {
                                model.settings.smartShiftThreshold = def
                                model.settings.wheelMode = .smartShift
                            }
                        }
                    }
                }
            } else {
                Section {
                    Label(model.mouse == nil ? "Connect your Logitech mouse to change how the wheel feels." : "This mouse doesn't let software change the wheel's feel.",
                          systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(poll) { _ in model.refreshMouse() }
    }

    private func modeRow(_ mode: WheelMode, selected: Bool) -> some View {
        Button {
            model.setWheelMode(mode)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mode.title).fontWeight(.medium)
                        if mode == .ratchet { Text("feels like a normal wheel").font(.caption).foregroundStyle(.secondary) }
                    }
                    Text(mode.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: mode.symbol)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
    }

    private var thresholdBinding: Binding<Double> {
        Binding {
            Double(model.settings.smartShiftThreshold)
        } set: {
            model.settings.smartShiftThreshold = Int($0)
            model.settings.wheelMode = .smartShift
        }
    }
}
