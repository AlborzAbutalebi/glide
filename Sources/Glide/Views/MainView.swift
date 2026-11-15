import AppKit
import SwiftUI

enum Pane: String, CaseIterable, Identifiable {
    case overview, scrolling, wheel, buttons, pointer, general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .scrolling: "Scrolling"
        case .wheel: "Scroll Wheel"
        case .buttons: "Buttons"
        case .pointer: "Pointer"
        case .general: "General"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "computermouse"
        case .scrolling: "scroll"
        case .wheel: "gearshape.2"
        case .buttons: "button.programmable"
        case .pointer: "cursorarrow.motionlines"
        case .general: "slider.horizontal.3"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var pane: Pane? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                ForEach(Pane.allCases) { p in
                    Label(p.title, systemImage: p.symbol)
                        .badge(p == .overview && model.needsAttention ? Text("!") : nil)
                        .tag(p)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Group {
                switch pane ?? .overview {
                case .overview: OverviewPane(pane: $pane)
                case .scrolling: ScrollingPane()
                case .wheel: WheelPane()
                case .buttons: ButtonsPane()
                case .pointer: PointerPane()
                case .general: GeneralPane()
                }
            }
            .frame(minWidth: 560, minHeight: 540)
            .navigationTitle((pane ?? .overview).title)
        }
        .onAppear {
            // Show in the Dock and app switcher while the window is open.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            model.refreshMouse()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Overview

struct OverviewPane: View {
    @EnvironmentObject var model: AppModel
    @Binding var pane: Pane?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if model.needsAttention { PermissionCard() }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    tile(.scrolling, title: "Scrolling", value: scrollingSummary, detail: scrollingDetail)
                    tile(.wheel, title: "Scroll wheel", value: model.effectiveWheelMode?.title ?? "—", detail: wheelDetail)
                    tile(.pointer, title: "Pointer", value: model.mouse?.supportsDPI == true ? "\(model.effectiveDPI) DPI" : "—",
                         detail: model.settings.pointerAcceleration == .off ? "Acceleration off" : "macOS acceleration")
                    tile(.buttons, title: "Gesture button", value: model.settings.gestureButton.action == .passthrough ? "Not used" : model.settings.gestureButton.action.title,
                         detail: model.settings.gestureMovementActive ? "Hold and move for gestures" : "Click only")
                }
                if let app = model.skippedApp {
                    Label("Smooth scrolling is paused in \(app), so each wheel click stays one step.", systemImage: "gamecontroller")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(LinearGradient(colors: [Color(red: 0.16, green: 0.36, blue: 0.95), Color(red: 0.05, green: 0.72, blue: 0.82)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "computermouse.fill")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 72, height: 72)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.mouse?.name ?? statusTitle)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let battery = model.mouse?.battery {
                BatteryLabel(percent: battery, charging: model.mouse?.charging ?? false)
                    .font(.title3)
            }
        }
    }

    private var statusTitle: String {
        switch model.hidStatus {
        case .needsInputMonitoring: "Mouse not readable yet"
        case .failed: "Couldn't open the mouse"
        default: "Looking for your mouse…"
        }
    }

    private var subtitle: String {
        guard let m = model.mouse else {
            return model.hidStatus == .needsInputMonitoring
                ? "Allow Input Monitoring for DPI, wheel mode and battery. Scrolling and buttons work without it."
                : "Turn the mouse on or move it to wake it. Smooth scrolling works with any mouse."
        }
        var parts = [m.transport]
        if let host = m.host, let count = m.hostCount { parts.append("Easy-Switch \(host) of \(count)") }
        if let fw = m.firmware { parts.append("Firmware \(fw)") }
        return parts.joined(separator: " · ")
    }

    private var scrollingSummary: String {
        guard model.settings.enabled else { return "Paused" }
        return model.settings.smoothScrolling ? "Smooth" : "Instant"
    }

    private var scrollingDetail: String {
        let lines = model.settings.linesPerClick
        let accel = model.settings.acceleration > 0 ? "with acceleration" : "linear"
        return "\(lines.formatted(.number.precision(.fractionLength(0...1)))) lines per click, \(accel)"
    }

    private var wheelDetail: String {
        guard let m = model.mouse, m.supportsSmartShift else { return "Needs a Logitech wheel with SmartShift" }
        return m.freeSpin == true ? "Spinning free right now" : "Clicking (ratchet) right now"
    }

    private func tile(_ target: Pane, title: String, value: String, detail: String) -> some View {
        Button {
            pane = target
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Label(title, systemImage: target.symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.05)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}
