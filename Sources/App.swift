import AppKit
import SwiftUI
import UserNotifications

@main
struct PaperRushBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = Store.shared
    /// Observed apart from the store, so glyph frames redraw the label and nothing else.
    @StateObject private var icon = Store.shared.icon

    var body: some Scene {
        MenuBarExtra {
            MenuView().environmentObject(store)
        } label: {
            // Glyph and title are one image, so colour and weight survive the menu bar.
            Image(nsImage: icon.image)
                .renderingMode(icon.isTemplate ? .template : .original)
                .id(icon.version)
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

    /// Clicking the update notice should land on the release notes, not just dismiss.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let string = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: string) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
