import SwiftUI

@main
struct NotheringApp: App {
  init() {
    // Also when iOS launches the app in the background for the Mac's Bluetooth wake, where no
    // window is made: the controller is what answers it.
    _ = ProxyController.shared
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
