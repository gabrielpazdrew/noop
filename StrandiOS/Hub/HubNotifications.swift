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
    /// Re-plan every hub notification from the current state. Call after each upload attempt
    /// (T4.1), when the app comes to the foreground, and when Settings change. Cheap and idempotent.
    static func refresh(state: HubState = .shared, now: Date = Date(),
                        center: HubNoticeCenter = UserNotificationHubCenter()) {
        let inputs = HubNoticeInputs(now: now,
                                     enabled: state.enabled,
                                     serverRenewalEstimate: state.serverRenewalEstimate,
                                     embeddedExpiry: SigningInfo.embeddedExpirationDate(),
                                     failingSince: state.failingSince,
                                     locked: state.locked,
                                     tripwire: state.tripwire)
        let (actions, memory) = HubNoticePlanner.plan(inputs, memory: state.noticeMemory)
        HubNoticeApplier.apply(actions, now: now, to: center)
        state.noticeMemory = memory
    }

    /// Ask for alert permission (once; iOS remembers the answer). Called when the hub is turned on.
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
#endif
