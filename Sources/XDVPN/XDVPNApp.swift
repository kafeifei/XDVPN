import SwiftUI

@main
struct XDVPNApp: App {
    @StateObject private var controller = VPNController()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(controller)
        } label: {
            Image(systemName: controller.isConnected
                  ? "lock.shield.fill"
                  : "lock.shield")
        }
        .menuBarExtraStyle(.window)
    }
}
