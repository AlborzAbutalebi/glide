import AppKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selftest") { exit(SelfTest.run()) }
        if args.contains("--probe") { exit(SelfTest.probe(write: args.contains("--write-same"))) }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            exit(MainActor.assumeIsolated { SelfTest.snapshot(to: args[i + 1]) })
        }
        GlideApp.main()
    }
}

struct GlideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Glide", id: "settings") {
            MainView()
                .environmentObject(model)
        }
        .defaultSize(width: 880, height: 640)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(model.showWindowAtLaunch ? .presented : .suppressed)

        MenuBarExtra {
            MenuBarMenu()
                .environmentObject(model)
        } label: {
            MenuBarLabel()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.menu)
    }
}

let showSettingsNotification = Notification.Name("local.peripherals.glide.show")

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one Glide at a time: hand over to the running copy and quit.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty {
            DistributedNotificationCenter.default().postNotificationName(showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
            exit(0)
        }
        DistributedNotificationCenter.default().addObserver(forName: showSettingsNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { AppModel.shared.showSettings() }
        }
        MainActor.assumeIsolated { AppModel.shared.start() }
    }

    /// Opening Glide again (Finder, Spotlight, Dock) shows the settings window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppModel.shared.showSettings() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.driver.shutdown() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
