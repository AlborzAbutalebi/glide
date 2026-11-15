import AppKit
import ApplicationServices
import IOKit.hid
import ServiceManagement
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var settings: AppSettings {
        didSet { if settings != oldValue { settingsChanged() } }
    }
    @Published private(set) var mouse: MouseState?
    @Published private(set) var hidStatus: HIDStatus = .searching
    @Published private(set) var accessibilityGranted = AXIsProcessTrusted()
    @Published private(set) var inputMonitoringGranted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    @Published private(set) var tapActive = false
    @Published private(set) var skippedApp: String?
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled

    let driver = Driver()
    /// Set by the menu bar label (always on screen), which has SwiftUI's openWindow.
    var openSettingsWindow: (() -> Void)?
    let showWindowAtLaunch: Bool
    private var started = false
    private var saveWork: DispatchWorkItem?
    private var timer: Timer?
    private var gameCache: [String: Bool] = [:]
    private var ticks = 0

    private init() {
        var s = AppSettings.load()
        showWindowAtLaunch = !s.hasLaunchedBefore || !AXIsProcessTrusted()
        if !s.hasLaunchedBefore {
            s.hasLaunchedBefore = true
            s.save()
        }
        settings = s
    }

    func start() {
        guard !started else { return }
        started = true
        Log.info("Glide starting (\(Bundle.main.bundlePath))")

        driver.onMouse = { [weak self] state in self?.mouseUpdated(state) }
        driver.onHIDStatus = { [weak self] status in self?.hidStatusChanged(status) }
        driver.actions.settingsAction = { [weak self] action in self?.perform(action) }
        driver.start(settings: settings)

        if !accessibilityGranted {
            // Shows the system prompt that leads to System Settings > Privacy > Accessibility.
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
        tryInstallTap()

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor in self?.frontmostChanged(app) }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.driver.reapplyAll()
                self?.driver.checkTap()
            }
        }
        frontmostChanged(NSWorkspace.shared.frontmostApplication)
    }

    private func mouseUpdated(_ state: MouseState?) {
        let before = mouse?.freeSpin
        mouse = state
        // The button behind the wheel flips ratchet / free-spin on the mouse itself. When the
        // mouse changed mode on its own, follow it, so the saved choice doesn't undo the
        // button the next time the mouse reconnects.
        guard let before, let now = state?.freeSpin, now != before,
              let saved = settings.wheelMode, let actual = state?.wheelMode,
              (actual == .freeSpin) != (saved == .freeSpin) else { return }
        settings.wheelMode = actual
    }

    private func hidStatusChanged(_ status: HIDStatus) {
        hidStatus = status
        // Ask for Input Monitoring only if macOS actually refuses access to the mouse.
        if status == .needsInputMonitoring, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
    }

    private func tick() {
        let ax = AXIsProcessTrusted()
        if ax != accessibilityGranted { accessibilityGranted = ax }
        let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if im != inputMonitoringGranted {
            inputMonitoringGranted = im
            if im, hidStatus == .needsInputMonitoring { driver.restartHID() }
        }
        if !tapActive { tryInstallTap() } else { driver.checkTap() }
        ticks += 1
        if ticks % 300 == 0 { driver.logStats() }
    }

    private func tryInstallTap() {
        guard AXIsProcessTrusted() else { return }
        tapActive = driver.installTap()
    }

    private func settingsChanged() {
        driver.update(settings: settings)
        frontmostChanged(NSWorkspace.shared.frontmostApplication)
        saveWork?.cancel()
        let snapshot = settings
        let work = DispatchWorkItem { snapshot.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    // MARK: - Apps where the wheel is left alone

    private func frontmostChanged(_ app: NSRunningApplication?) {
        let skip = app.map(shouldSkip) ?? false
        let name = skip ? app?.localizedName : nil
        if name != skippedApp { skippedApp = name }
        driver.setSkipScrolling(skip)
    }

    private func shouldSkip(_ app: NSRunningApplication) -> Bool {
        if let id = app.bundleIdentifier, settings.excludedApps.contains(id) { return true }
        guard settings.skipGames else { return false }
        let key = app.bundleURL?.path ?? app.executableURL?.path ?? "\(app.processIdentifier)"
        if let cached = gameCache[key] { return cached }
        let game = Self.looksLikeGame(app)
        gameCache[key] = game
        if game { Log.info("leaving the wheel alone in \(app.localizedName ?? key) (looks like a game)") }
        return game
    }

    /// Games use each wheel event as one "step" (next hotbar slot, zoom level...), so smooth
    /// scrolling's stream of small events would skip several steps per click.
    static func looksLikeGame(_ app: NSRunningApplication) -> Bool {
        let id = (app.bundleIdentifier ?? "").lowercased()
        let path = (app.bundleURL?.path ?? app.executableURL?.path ?? "").lowercased()
        let exe = app.executableURL?.lastPathComponent.lowercased() ?? ""
        if path.contains("/steamapps/") || id.hasPrefix("unity.") { return true }
        if exe == "java" || id.contains("openjdk") || id.hasPrefix("net.java") || id.contains("minecraft") { return true }
        if let url = app.bundleURL, let bundle = Bundle(url: url),
           let category = bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String,
           category.hasSuffix("games") { return true }
        return false
    }

    // MARK: - Actions from the UI and from buttons

    func perform(_ action: MouseAction) {
        switch action {
        case .toggleWheelMode:
            if mouse?.supportsSmartShift == true { driver.toggleWheelMode { _ in } }
        case .cycleDPI:
            let presets = settings.dpiPresets.sorted()
            guard !presets.isEmpty else { return }
            let current = settings.dpi ?? mouse?.dpi ?? presets[0]
            settings.dpi = presets.first { $0 > current } ?? presets[0]
        case .toggleSmoothScrolling:
            settings.smoothScrolling.toggle()
        default:
            break
        }
    }

    func showSettings() {
        openSettingsWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func setWheelMode(_ mode: WheelMode) {
        settings.wheelMode = mode
    }

    func refreshMouse() {
        driver.refresh()
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.info("launch at login: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func resetAll() {
        var fresh = AppSettings()
        fresh.hasLaunchedBefore = true
        settings = fresh
    }

    func openPrivacyPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Fills in state without a driver, for `--snapshot` renders of the settings panes.
    func preview(mouse: MouseState?, accessibility: Bool, hid: HIDStatus) {
        self.mouse = mouse
        accessibilityGranted = accessibility
        hidStatus = hid
    }

    // MARK: - Derived values for the UI

    var effectiveWheelMode: WheelMode? { mouse?.wheelMode ?? settings.wheelMode }

    var effectiveDPI: Int { settings.dpi ?? mouse?.dpi ?? 1000 }

    var needsAttention: Bool { !accessibilityGranted || hidStatus == .needsInputMonitoring }
}
