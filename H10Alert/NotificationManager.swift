import Foundation
import UserNotifications
import UIKit

@MainActor
final class NotificationManager: NSObject {

    // MARK: - Singleton
    static let shared = NotificationManager()
    
    private var tokenUploadURL: URL?
    private var authorizationHeader: String?

    private let center = UNUserNotificationCenter.current()
    private var session: URLSession = .shared

    // Cached token so we can re-upload (e.g. after login) without waiting for a new APNs callback.
    private(set) var deviceToken: String?

    private override init() {
        super.init()
        center.delegate = self
    }
    
    func configure(tokenUploadURL: URL, authorizationHeader: String? = nil, session: URLSession = .shared) {
        self.tokenUploadURL = tokenUploadURL
        self.authorizationHeader = authorizationHeader
        self.session = session
    }
    
    @discardableResult
    func requestAuthorization(options: UNAuthorizationOptions = [.alert, .badge, .sound]) async throws -> Bool {
        let granted = try await center.requestAuthorization(options: options)
        if granted {
            registerForRemoteNotifications()
        }
        return granted
    }
    
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }
    
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
    
    func setDeviceToken(_ rawToken: Data) {
        let token = rawToken.map { String(format: "%02x", $0) }.joined()
        deviceToken = token
        Task {
            do {
                try await uploadToken(token)
            } catch {
                // Swallow-and-log here; a real app might retry with backoff.
                print("[NotificationManager] Token upload failed: \(error)")
            }
        }
    }
    
    func registrationDidFail(_ error: Error) {
        print("[NotificationManager] Remote registration failed: \(error)")
    }
    
    func uploadToken(_ token: String) async throws {
        guard let tokenUploadURL else { throw NotificationError.notConfigured }
        var request = URLRequest(url: tokenUploadURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let authorizationHeader {
            request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        }

        let payload = TokenPayload(
            token: token,
            platform: "ios",
            bundleId: Bundle.main.bundleIdentifier ?? "unknown",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NotificationError.uploadFailed(statusCode: code)
        }
    }

    private struct TokenPayload: Encodable {
        let token: String
        let platform: String
        let bundleId: String
        let appVersion: String?
    }
    
    // Schedules a local notification after a delay.
    // - Returns: the request identifier, which you can later pass to `cancel(identifier:)`.
    @discardableResult
    func scheduleLocalNotification(title: String, body: String, after interval: TimeInterval, repeats: Bool = false, identifier: String = UUID().uuidString, userInfo: [AnyHashable: Any] = [:]) async throws -> String {
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 1), repeats: repeats)
        try await schedule(title: title, body: body, identifier: identifier, userInfo: userInfo, trigger: trigger)
        return identifier
    }

    // Schedules a local notification for a specific calendar date.
    @discardableResult
    func scheduleLocalNotification(title: String, body: String, at date: DateComponents, repeats: Bool = false, identifier: String = UUID().uuidString, userInfo: [AnyHashable: Any] = [:]) async throws -> String {
        let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: repeats)
        try await schedule(title: title, body: body, identifier: identifier, userInfo: userInfo, trigger: trigger)
        return identifier
    }

    private func schedule(title: String, body: String, identifier: String, userInfo: [AnyHashable: Any], trigger: UNNotificationTrigger) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: trigger
        )
        try await center.add(request)
    }

    // Cancels a pending (not-yet-delivered) notification.
    func cancel(identifier: String) {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    // Cancels everything pending and clears delivered notifications.
    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    enum NotificationError: LocalizedError {
        case notConfigured
        case uploadFailed(statusCode: Int)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "NotificationManager.configure(...) must be called before uploading a token."
            case .uploadFailed(let code):
                return "Token upload failed with status code \(code)."
            }
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {

    // Lets notifications show while the app is in the foreground.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .badge, .sound]
    }

    // Called when the user taps a notification.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let userInfo = response.notification.request.content.userInfo
        print("[NotificationManager] Tapped notification: \(userInfo)")
        // Route to the relevant screen here.
    }
}

