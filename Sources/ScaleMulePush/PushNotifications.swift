#if canImport(UIKit)
import UIKit
import UserNotifications
import Combine
import CryptoKit
import ScaleMuleCore

public enum PushPermission: String, Sendable {
    case notDetermined, denied, authorized, provisional, ephemeral
    public var allowsNotifications: Bool { self == .authorized || self == .provisional || self == .ephemeral }
}

@MainActor protocol PushSystem: AnyObject {
    func permission() async -> PushPermission
    func requestPermission() async throws -> Bool
    func register()
    func unregister()
    func removeDeliveredNotifications()
    func setBadge(_ count: Int) async throws
}

@MainActor final class ApplePushSystem: PushSystem {
    func permission() async -> PushPermission {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized: return .authorized
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        case .denied: return .denied
        default: return .notDetermined
        }
    }
    func requestPermission() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }
    func register() { UIApplication.shared.registerForRemoteNotifications() }
    func unregister() { UIApplication.shared.unregisterForRemoteNotifications() }
    func removeDeliveredNotifications() { UNUserNotificationCenter.current().removeAllDeliveredNotifications() }
    func setBadge(_ count: Int) async throws {
        try await UNUserNotificationCenter.current().setBadgeCount(max(0, count))
    }
}

/// Native APNs lifecycle shared by all ScaleMule iOS apps. A permission prompt
/// happens only after the app calls requestAuthorization from a user action.
@MainActor public final class PushNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published public private(set) var permission: PushPermission = .notDetermined
    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var isRegistered = false
    @Published public private(set) var isWorking = false
    @Published public private(set) var lastError: String?

    /// The app owns navigation. Never open arbitrary payload URLs automatically.
    /// Called for a matching notification while the app is active, before presentation.
    public var onForegroundNotification: (([AnyHashable: Any]) -> Void)?
    public var onNotificationTap: (([AnyHashable: Any]) -> Void)?
    public var foregroundPresentationOptions: UNNotificationPresentationOptions = [.banner, .list, .badge, .sound]

    private let app: ScaleMuleApp
    private let service: PushService
    private let system: PushSystem
    private let defaults: UserDefaults
    private let preferenceKey: String
    private let registrationKey: String
    private let logger = SMLogger(category: "Push")
    private var currentUserId: String?
    private var binding: (id: String, userId: String, session: String)?
    private var authTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var installed = false
    private var pendingTap: [AnyHashable: Any]?

    public convenience init(app: ScaleMuleApp) {
        self.init(app: app, system: ApplePushSystem(), defaults: .standard)
        // A cold-start response can arrive before SwiftUI onAppear.
        UNUserNotificationCenter.current().delegate = self
    }

    init(app: ScaleMuleApp, system: PushSystem, defaults: UserDefaults) {
        self.app = app
        self.service = PushService(app: app)
        self.system = system
        self.defaults = defaults
        let scope = SHA256.hash(data: Data(app.config.apiKey.utf8)).map { String(format: "%02x", $0) }.joined()
        preferenceKey = "com.scalemule.push.\(scope).enabled"
        registrationKey = "com.scalemule.push.\(scope).registration"
        isEnabled = defaults.bool(forKey: preferenceKey)
        super.init()
    }

    deinit { authTask?.cancel(); operation?.cancel() }

    /// Install early, normally from the SDK app delegate's property assignment.
    public func install() {
        UNUserNotificationCenter.current().delegate = self
        guard !installed else { return }
        installed = true
        let sdkApp = app
        authTask = Task { [weak self] in
            let stream = await sdkApp.authStateStream()
            for await state in stream {
                guard !Task.isCancelled, let self else { return }
                switch state {
                case .authenticated(let user):
                    if self.currentUserId != user.id {
                        if self.currentUserId != nil { await self.deactivateBeforeSignOut() }
                        self.currentUserId = user.id
                    }
                    await self.refresh()
                    if let pending = self.pendingTap {
                        self.pendingTap = nil
                        if self.isEnabled, Self.matchesRecipient(pending, userId: user.id) {
                            self.onNotificationTap?(pending)
                        }
                    }
                case .unauthenticated:
                    await self.deactivateBeforeSignOut()
                default: break
                }
            }
        }
    }

    /// Call only in response to a person choosing to enable notifications.
    @discardableResult public func requestAuthorization() async -> Bool {
        lastError = nil
        do {
            let allowed = try await system.requestPermission()
            isEnabled = allowed
            defaults.set(allowed, forKey: preferenceKey)
            await refresh()
            return allowed
        } catch {
            fail("Notifications couldn’t be enabled. Please try again.")
            return false
        }
    }

    /// Refresh after returning from iOS Settings or foregrounding the app.
    /// Does not display a permission prompt.
    public func refresh() async {
        permission = await system.permission()
        guard isEnabled, permission.allowsNotifications, currentUserId != nil else {
            system.unregister()
            await removeBinding()
            return
        }
        lastError = nil
        system.register()
    }

    public func setEnabled(_ enabled: Bool) async {
        if enabled {
            if await system.permission() == .notDetermined {
                _ = await requestAuthorization()
                return
            }
            isEnabled = true
            defaults.set(true, forKey: preferenceKey)
            await refresh()
        } else {
            isEnabled = false
            defaults.set(false, forKey: preferenceKey)
            system.unregister()
            await removeBinding()
            await clearBadge()
        }
    }

    /// Forward UIApplicationDelegate's didRegister callback here. No token is logged.
    public func didRegister(deviceToken: Data) {
        guard isEnabled, permission.allowsNotifications, let userId = currentUserId else { return }
        let previous = operation
        operation = Task { [weak self] in
            await previous?.value
            guard let self, self.isEnabled, self.currentUserId == userId,
                  let session = await self.app.sessionManager.sessionToken else { return }
            self.isWorking = true
            self.isRegistered = false
            defer { self.isWorking = false }
            let result = await self.service.register(deviceToken: deviceToken, userId: userId, session: session,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                osVersion: UIDevice.current.systemVersion)
            guard case .success(let registration) = result else {
                self.fail("Couldn’t register this device for notifications. Please try again.")
                return
            }
            // A sign-out or disable can happen while the request is in flight.
            guard self.isEnabled, self.currentUserId == userId else {
                let cleanup = await self.service.unregister(id: registration.id, session: session)
                if !cleanup.isSuccess { self.logger.error("Push registration cleanup failed after account change") }
                return
            }
            self.binding = (registration.id, userId, session)
            self.defaults.set(["id": registration.id, "userId": userId], forKey: self.registrationKey)
            // Reactivation intentionally preserves the server's device setting;
            // explicit local opt-in enables it again after a previous disable.
            let enabled = await self.service.setEnabled(true, id: registration.id, session: session)
            self.isRegistered = enabled.isSuccess
            if !enabled.isSuccess { self.fail("Couldn’t enable notifications on this device. Please try again.") }
        }
    }

    public func didFailToRegister(error: Error) {
        isRegistered = false
        fail("Apple couldn’t register this device for notifications. Please try again.")
    }

    /// Call BEFORE clearing/revoking the user's session. The OS is unregistered
    /// immediately; server cleanup uses the session that created the binding.
    public func deactivateBeforeSignOut() async {
        currentUserId = nil
        pendingTap = nil
        system.unregister()
        system.removeDeliveredNotifications()
        await removeBinding()
        await clearBadge()
    }

    public func clearBadge() async {
        _ = await setBadgeCount(0)
    }

    /// Set the home-screen icon only. This never marks Inbox items or messages
    /// read. Apps can clear on activation or use their own authoritative count.
    @discardableResult
    public func setBadgeCount(_ count: Int) async -> Bool {
        do {
            try await system.setBadge(max(0, count))
            return true
        } catch {
            logger.error("Could not update the notification badge")
            return false
        }
    }

    /// Resume if an account-deletion attempt failed and the user remains signed in.
    public func resume() async {
        if case .authenticated(let user) = await app.authState.state {
            currentUserId = user.id
            await refresh()
        }
    }

    private func removeBinding() async {
        await operation?.value
        isRegistered = false
        var old = binding
        if old == nil, let saved = defaults.dictionary(forKey: registrationKey),
           let id = saved["id"] as? String, let user = saved["userId"] as? String,
           let remembered = await app.sessionManager.rememberedUser(), remembered.id == user,
           let session = await app.sessionManager.sessionToken {
            old = (id, user, session)
        }
        guard let old else { return }
        let result = await service.unregister(id: old.id, userId: old.userId, originalSession: old.session)
        if result.isSuccess {
            binding = nil
            defaults.removeObject(forKey: registrationKey)
        } else {
            logger.error("Push device cleanup failed; retrying on the next account transition")
            lastError = "This device couldn’t be disconnected from notifications. Please try again when online."
        }
    }

    private func fail(_ message: String) { lastError = message; logger.error(message) }

    static func matchesRecipient(_ payload: [AnyHashable: Any], userId: String) -> Bool {
        guard let recipient = payload["recipient_user_id"] else { return true }
        return recipient as? String == userId
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            let matches = currentUserId.map { Self.matchesRecipient(notification.request.content.userInfo, userId: $0) } ?? false
            if isEnabled && matches { onForegroundNotification?(notification.request.content.userInfo) }
            completionHandler(isEnabled && matches ? foregroundPresentationOptions : [])
        }
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else {
                completionHandler()
                return
            }
            let payload = response.notification.request.content.userInfo
            if isEnabled {
                if let currentUserId {
                    if Self.matchesRecipient(payload, userId: currentUserId) { onNotificationTap?(payload) }
                } else { pendingTap = payload }
            }
            completionHandler()
        }
    }
}

/// SwiftUI: @UIApplicationDelegateAdaptor(ScaleMulePushAppDelegate.self).
/// Assign pushNotifications early. Apps with their own delegate can instead
/// forward the two APNs callbacks directly to PushNotifications.
@MainActor public final class ScaleMulePushAppDelegate: NSObject, UIApplicationDelegate {
    public var pushNotifications: PushNotifications? {
        didSet {
            pushNotifications?.install()
            if let pendingToken { pushNotifications?.didRegister(deviceToken: pendingToken); self.pendingToken = nil }
        }
    }
    private var pendingToken: Data?
    public func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        if let pushNotifications { pushNotifications.didRegister(deviceToken: deviceToken) }
        else { pendingToken = deviceToken }
    }
    public func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        pushNotifications?.didFailToRegister(error: error)
    }
}
#endif
