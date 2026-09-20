import SwiftUI
import UserNotifications

@main
struct PaperRushBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(store)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "hourglass")
                Text(verbatim: store.menuBarTitle)
            }
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor in
            Store.shared.requestNotificationAuthorization()
            Store.shared.bootstrap()
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
