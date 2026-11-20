import SwiftUI
import UIKit

@main
struct NotheringApp: App {
  @UIApplicationDelegateAdaptor private var delegate: AppDelegate

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}

/// Makes the controller where iOS expects an app's Bluetooth to come back to life: at the end of
/// launching, also when it launches the app in the background for the Mac's Bluetooth wake, where
/// no window is made. The controller is what answers the wake.
final class AppDelegate: NSObject, UIApplicationDelegate {
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    _ = ProxyController.shared
    return true
  }
}
