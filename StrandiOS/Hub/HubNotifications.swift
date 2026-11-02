// Fork-only (phone-hub). The UserNotifications side of the hub's local notifications. All the
// decisions are in Core/HubNoticePlanner.swift; this file only feeds it and applies its plan.
#if os(iOS)
import Foundation
import UserNotifications

/// UNUserNotificationCenter as a HubNoticeCenter. `add` with an existing identifier replaces the
/// pending request, and the applier removes first anyway, so each kind has at most one.
final class UserNotificationHubCenter: HubNoticeCenter {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) { self.center = center }

    func removeNotices(ids: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    func addNotice(id: String, title: String, body: String, after seconds: TimeInterval) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

enum HubNotifications {
    /// Re-plan every hub notification from the current state. Called after each upload attempt
    /// (HubUploader), when the app comes to the foreground (HubUploader.sceneBecameActive), when
    /// Settings change, once the notification prompt is answered, and on every band connect, drop and
    /// strap sync (HubUploader.watchBackfilling). Cheap and idempotent; callable
    /// from any thread.
    ///
    /// Plan + apply + save run on the main actor, one refresh at a time, so two callers can never both
    /// read un-armed memory and post a due-now banner twice (T4.3 review finding 2). When the app may
    /// not show notifications, nothing is applied and the memory is left as it was (finding 1).
    static func refresh(state: HubState = .shared, now: Date? = nil,
                        center: HubNoticeCenter? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let canNotify: Bool
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral: canNotify = true
            default: canNotify = false
            }
            Task { @MainActor in
                apply(state: state, now: now ?? Date(), canNotify: canNotify,
                      center: center ?? UserNotificationHubCenter())
            }
        }
    }

    /// The current connection's half of the band-link clock (in memory; HubState keeps the rest).
    @MainActor private static var linkTracker = HubLinkTracker()

    @MainActor
    private static func apply(state: HubState, now: Date, canNotify: Bool, center: HubNoticeCenter) {
        // Band link first (PLAN-BAND-LINK T3): tracked even while the hub is off or notifications are
        // denied, so the clock is right the moment either changes. No AppModel yet = no new observation.
        if let live = AppModel.shared?.live {
            state.linkMemory = linkTracker.observe(connected: live.connected,
                                                   lastSyncedAt: live.lastSyncedAt.map { Date(timeIntervalSince1970: $0) },
                                                   now: now, memory: state.linkMemory)
        }
        let inputs = HubNoticeInputs(now: now,
                                     enabled: state.enabled,
                                     serverRenewalEstimate: state.serverRenewalEstimate,
                                     embeddedExpiry: SigningInfo.embeddedExpirationDate(),
                                     failingSince: state.failingSince,
                                     locked: state.locked,
                                     tripwire: state.tripwire,
                                     bandLostSince: linkTracker.lostSince(memory: state.linkMemory))
        state.noticeMemory = HubNoticeRefresher.refresh(inputs, memory: state.noticeMemory,
                                                        canNotify: canNotify, center: center)
    }

    /// Ask for alert permission (once; iOS remembers the answer). Called when the hub is turned on.
    /// Re-plans once the user has answered, so a notice held back while the prompt was open goes out.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            refresh()
        }
    }
}
#endif
