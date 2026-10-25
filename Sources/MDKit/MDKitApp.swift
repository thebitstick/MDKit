import SwiftUI
import NetMDKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        DeviceController.current?.prepareForQuit() ?? .terminateNow
    }
}

@main
struct MDKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var device = DeviceController()
    @State private var importing = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(device)
                .frame(minWidth: 760, minHeight: 520)
        }
        // A real window rather than a sheet: AppKit refuses to quit while a sheet is attached, which made ⌘Q
        // useless mid-rip, exactly when quitting cleanly matters.
        Window("Homebrew Mode Ripping", id: "ripper") {
            HomebrewRippingView()
                .environmentObject(device)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Audio Files…") { NotificationCenter.default.post(name: .addFiles, object: nil) }
                    .keyboardShortcut("o")
                    .disabled(device.connected == nil)
            }
            CommandMenu("Disc") {
                Button("Refresh") { Task { await device.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(device.connected == nil)
                Button("Eject") { Task { await device.eject() } }
                    .keyboardShortcut("e")
                    .disabled(device.connected == nil)
                Button("Homebrew Ripping…") { NotificationCenter.default.post(name: .showRipper, object: nil) }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(device.connected == nil)
                Divider()
                Button("Disconnect") { device.disconnect() }
                    .disabled(device.connected == nil)
            }
        }
    }
}

extension Notification.Name {
    static let addFiles = Notification.Name("mdkit.addFiles")
    static let showRipper = Notification.Name("mdkit.showRipper")
}
