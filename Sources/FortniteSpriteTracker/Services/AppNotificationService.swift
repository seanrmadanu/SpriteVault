import Foundation
import UserNotifications
import AppKit

extension Notification.Name {
    static let spriteNotificationSelected = Notification.Name("SpriteVault.SpriteNotificationSelected")
    static let activityNotificationSelected = Notification.Name("SpriteVault.ActivityNotificationSelected")
    static let spriteVaultOpenMainWindow = Notification.Name("SpriteVault.OpenMainWindow")
}

/// Native notifications for the real macOS app, with a safe AppleScript fallback
/// when somebody still launches the repository as a bare Swift Package target.
final class AppNotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = AppNotificationService()

    enum PendingDestination: Sendable {
        case sprite(String)
        case activity
    }

    private let center: UNUserNotificationCenter?
    private let routeLock = NSLock()
    private var pendingDestination: PendingDestination?
    private let usesNativeNotificationCenter: Bool

    private override init() {
        let mainBundle = Bundle.main
        let isApplicationBundle =
            mainBundle.bundleURL.pathExtension.lowercased() == "app" &&
            mainBundle.bundleIdentifier != nil

        usesNativeNotificationCenter = isApplicationBundle
        center = isApplicationBundle ? UNUserNotificationCenter.current() : nil
        super.init()
        center?.delegate = self
    }

    var isUsingNativeNotifications: Bool { usesNativeNotificationCenter }

    func consumePendingDestination() -> PendingDestination? {
        routeLock.lock()
        defer { routeLock.unlock() }
        let destination = pendingDestination
        pendingDestination = nil
        return destination
    }

    private func rememberPendingDestination(_ destination: PendingDestination) {
        routeLock.lock()
        pendingDestination = destination
        routeLock.unlock()
    }

    func authorizationGranted() async -> Bool {
        guard let center else { return true }
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning:
                    settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional
                )
            }
        }
    }

    func requestAuthorization() async -> Bool {
        guard let center else { return true }
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func send(
        title: String,
        body: String,
        sound: UNNotificationSound? = .default,
        identifier: String = UUID().uuidString,
        spriteName: String? = nil,
        openActivityCenter: Bool = false
    ) {
        if let center {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = sound
            var userInfo: [String: String] = [:]
            if let spriteName { userInfo["spriteName"] = spriteName }
            if openActivityCenter { userInfo["openActivityCenter"] = "true" }
            content.userInfo = userInfo

            center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil)) { error in
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
        [.banner, .sound, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let spriteName = info["spriteName"] as? String
        let openActivity = (info["openActivityCenter"] as? String) == "true"

        if let spriteName {
            rememberPendingDestination(.sprite(spriteName))
        } else if openActivity {
            rememberPendingDestination(.activity)
        }

        await MainActor.run {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NSApplication.shared.windows.first(where: \.canBecomeKey)?.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: .spriteVaultOpenMainWindow, object: nil)

            // Post immediately for a running UI. The pending route remains as a
            // cold-launch fallback and is consumed by ContentView on appearance.
            if let spriteName {
                NotificationCenter.default.post(
                    name: .spriteNotificationSelected,
                    object: nil,
                    userInfo: ["spriteName": spriteName]
                )
            } else if openActivity {
                NotificationCenter.default.post(name: .activityNotificationSelected, object: nil)
            }
        }
    }

    private func sendDevelopmentNotification(title: String, body: String, playSound: Bool) {
        let safeTitle = escapeForAppleScript(title)
        let safeBody = escapeForAppleScript(body)
        let soundClause = playSound ? " sound name \"Glass\"" : ""
        let script = "display notification \"\(safeBody)\" with title \"\(safeTitle)\"\(soundClause)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        do { try process.run() }
        catch { print("Development notification fallback failed: \(error.localizedDescription)") }
    }

    private func escapeForAppleScript(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
