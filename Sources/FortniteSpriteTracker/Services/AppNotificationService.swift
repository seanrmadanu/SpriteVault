import Foundation
import UserNotifications

/// Notification delivery that works both when the project is launched as a
/// normal .app bundle and when Xcode runs this repository as a Swift Package
/// executable.
///
/// UNUserNotificationCenter.current() requires a real application bundle on
/// macOS. Calling it from SwiftPM's bare executable can raise an Objective-C
/// exception before Swift gets a chance to catch it. We therefore only touch
/// UNUserNotificationCenter when Bundle.main is a real .app. During SwiftPM
/// development runs we fall back to macOS's `osascript display notification`
/// command so scan notifications still work without crashing the tracker.
final class AppNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationService()

    private let center: UNUserNotificationCenter?
    private let usesNativeNotificationCenter: Bool

    private override init() {
        let mainBundle = Bundle.main
        let isApplicationBundle =
            mainBundle.bundleURL.pathExtension.lowercased() == "app" &&
            mainBundle.bundleIdentifier != nil

        usesNativeNotificationCenter = isApplicationBundle

        // IMPORTANT: Do not call UNUserNotificationCenter.current() at all for
        // a Swift Package executable. On macOS that call can throw the
        // "bundleProxyForCurrentProcess is nil" Objective-C exception shown in
        // Xcode, which cannot be handled with Swift's do/catch.
        if isApplicationBundle {
            center = UNUserNotificationCenter.current()
        } else {
            center = nil
        }

        super.init()
        center?.delegate = self
    }

    /// True when the process is running as a real macOS application bundle and
    /// can use UserNotifications directly.
    var isUsingNativeNotifications: Bool {
        usesNativeNotificationCenter
    }

    func authorizationGranted() async -> Bool {
        guard let center else {
            // SwiftPM development mode uses the AppleScript fallback. There is
            // no UNUserNotificationCenter permission prompt to query here.
            return true
        }

        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(
                    returning: settings.authorizationStatus == .authorized ||
                        settings.authorizationStatus == .provisional
                )
            }
        }
    }

    func requestAuthorization() async -> Bool {
        guard let center else {
            // The fallback does not use UNUserNotificationCenter, so requesting
            // its authorization would just recreate the SwiftPM launch crash.
            return true
        }

        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func send(
        title: String,
        body: String,
        sound: UNNotificationSound? = .default,
        identifier: String = UUID().uuidString
    ) {
        if let center {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )

            center.add(request) { error in
                if let error {
                    print("Notification delivery failed: \(error.localizedDescription)")
                }
            }
            return
        }

        sendDevelopmentNotification(title: title, body: body, playSound: sound != nil)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Fallback used only when Xcode launches the Swift Package executable
    /// directly instead of launching a .app bundle.
    private func sendDevelopmentNotification(
        title: String,
        body: String,
        playSound: Bool
    ) {
        let safeTitle = escapeForAppleScript(title)
        let safeBody = escapeForAppleScript(body)
        let soundClause = playSound ? " sound name \"Glass\"" : ""
        let script = "display notification \"\(safeBody)\" with title \"\(safeTitle)\"\(soundClause)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]

        do {
            try process.run()
        } catch {
            print("Development notification fallback failed: \(error.localizedDescription)")
        }
    }

    private func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
