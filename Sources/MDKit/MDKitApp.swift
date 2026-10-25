import SwiftUI
import NetMDKit

@main
struct MDKitApp: App {
    @StateObject private var device = DeviceController()
    @State private var importing = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(device)
                .frame(minWidth: 760, minHeight: 520)
        }
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
