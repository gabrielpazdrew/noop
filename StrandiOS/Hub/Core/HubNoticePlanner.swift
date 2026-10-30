// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// Every decision about the hub's local notifications lives here as plain functions: which kind is
// due, when, and whether it already went out. HubNotifications.swift only feeds this the current
// state and hands the result to UNUserNotificationCenter.
import Foundation

/// The four hub notifications. One stable request id per kind, so re-planning replaces, never stacks.
enum HubNoticeKind: String, CaseIterable {
    case renewal, uploadsFailing, hubLocked, tripwire
    var identifier: String { "hub.notice.\(rawValue)" }
}

/// One notification to deliver at `fireAt` (a time at or before `now` means "as soon as possible").
struct HubNotice: Equatable {
    let kind: HubNoticeKind
    let title: String
    let body: String
    let fireAt: Date
}

enum HubNoticeAction: Equatable {
    case schedule(HubNotice)
    case cancel(HubNoticeKind)
}

/// What the planner has already armed, persisted between runs (HubState) so a notice that already
/// went out isn't repeated on every upload. Armed = scheduled for later, or delivered.
struct HubNoticeMemory: Equatable {
    /// The renewal estimate the reminder was armed for.
    var renewalArmedFor: Date? = nil
    /// The `failingSince` of the failure streak the "uploads failing" notice was armed for.
    var failureArmedFor: Date? = nil
    var lockedAlerted: Bool = false
    var tripwireAlerted: Bool = false
}

struct HubNoticeInputs {
    let now: Date
    /// The hub switch in Settings. Off silences failing / locked / tripwire; renewal is about NOOP
    /// itself expiring, so it is planned either way.
    let enabled: Bool
    /// The connector's renewal estimate, from the last upload response (T4.1). nil = never heard.
    let serverRenewalEstimate: Date?
    /// `ExpirationDate` from embedded.mobileprovision (SigningInfo).
    let embeddedExpiry: Date?
    /// Start of the current run of failed uploads; nil after a success.
    let failingSince: Date?
    let locked: Bool
    let tripwire: Bool
}

enum HubNoticePlanner {
    static let renewalLead: TimeInterval = 3 * 86_400
    static let failureGrace: TimeInterval = 6 * 3_600

    /// The later of the two dates (either may be missing). The server learns of a refresh only
    /// after the phone tells it, and the embedded profile only changes on a re-sign, so whichever
    /// is later is the freshest knowledge.
    static func renewalEstimate(server: Date?, embedded: Date?) -> Date? {
        switch (server, embedded) {
        case let (s?, e?): return max(s, e)
        case let (s?, nil): return s
        case let (nil, e?): return e
        case (nil, nil): return nil
        }
    }

    static func plan(_ i: HubNoticeInputs, memory: HubNoticeMemory) -> (actions: [HubNoticeAction], memory: HubNoticeMemory) {
        var actions: [HubNoticeAction] = []
        var m = memory

        // Renewal: estimate − 3 days. A future reminder is (re)scheduled every time (same id, so it
        // replaces); a reminder already due fires once per estimate.
        if let estimate = renewalEstimate(server: i.serverRenewalEstimate, embedded: i.embeddedExpiry) {
            let due = estimate.addingTimeInterval(-renewalLead)
            if due > i.now {
                actions.append(.schedule(notice(.renewal, fireAt: due, renewalEstimate: estimate)))
                m.renewalArmedFor = estimate
            } else if m.renewalArmedFor != estimate {
                actions.append(.schedule(notice(.renewal, fireAt: i.now, renewalEstimate: estimate)))
                m.renewalArmedFor = estimate
            }
        } else if m.renewalArmedFor != nil {
            actions.append(.cancel(.renewal))
            m.renewalArmedFor = nil
        }

        // Uploads failing: only once the streak is 6 h old. Scheduled ahead for failingSince + 6 h
        // (fires even if no upload is attempted in between); a success clears failingSince and
        // cancels it.
        if i.enabled, let since = i.failingSince {
            let due = since.addingTimeInterval(failureGrace)
            if due > i.now {
                actions.append(.schedule(notice(.uploadsFailing, fireAt: due, renewalEstimate: nil)))
                m.failureArmedFor = since
            } else if m.failureArmedFor != since {
                actions.append(.schedule(notice(.uploadsFailing, fireAt: i.now, renewalEstimate: nil)))
                m.failureArmedFor = since
            }
        } else if m.failureArmedFor != nil {
            actions.append(.cancel(.uploadsFailing))
            m.failureArmedFor = nil
        }

        // Locked and tripwire: once per false → true transition.
        // (Each kind is cancelled only when it was armed, so a quiet state yields an empty plan.)
        if i.enabled && i.locked {
            if !m.lockedAlerted {
                actions.append(.schedule(notice(.hubLocked, fireAt: i.now, renewalEstimate: nil)))
                m.lockedAlerted = true
            }
        } else if m.lockedAlerted {
            actions.append(.cancel(.hubLocked))
            m.lockedAlerted = false
        }
        if i.enabled && i.tripwire {
            if !m.tripwireAlerted {
                actions.append(.schedule(notice(.tripwire, fireAt: i.now, renewalEstimate: nil)))
                m.tripwireAlerted = true
            }
        } else if m.tripwireAlerted {
            actions.append(.cancel(.tripwire))
            m.tripwireAlerted = false
        }

        return (actions, m)
    }

    /// Notification text. Never carries health numbers; the renewal date is the only value shown.
    static func notice(_ kind: HubNoticeKind, fireAt: Date, renewalEstimate: Date?) -> HubNotice {
        switch kind {
        case .renewal:
            let when = renewalEstimate.map { "around " + DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? "soon"
            return HubNotice(kind: kind, title: "Refresh NOOP in SideStore",
                             body: "NOOP's signing runs out \(when). Open SideStore and refresh it, or NOOP stops opening.",
                             fireAt: fireAt)
        case .uploadsFailing:
            return HubNotice(kind: kind, title: "Hub uploads failing",
                             body: "NOOP hasn't reached your hub for 6 hours. Open NOOP, More, Health Hub to see why.",
                             fireAt: fireAt)
        case .hubLocked:
            return HubNotice(kind: kind, title: "Hub locked",
                             body: "Your hub is refusing uploads because it is locked. Unlock it from the Mac.",
                             fireAt: fireAt)
        case .tripwire:
            return HubNotice(kind: kind, title: "Hub tripwire",
                             body: "Something called your hub's decoy. Check the hub's security alerts.",
                             fireAt: fireAt)
        }
    }
}

/// The slice of a notification center the applier needs. UNUserNotificationCenter in the app
/// (HubNotifications.swift), a fake in tests.
protocol HubNoticeCenter: AnyObject {
    /// Remove pending AND delivered notifications with these ids.
    func removeNotices(ids: [String])
    /// Add a one-shot notification that fires `seconds` from now (always ≥ 1).
    func addNotice(id: String, title: String, body: String, after seconds: TimeInterval)
}

enum HubNoticeApplier {
    /// Every schedule removes its id first, so a center that appends instead of replacing still
    /// ends with at most one request per kind.
    static func apply(_ actions: [HubNoticeAction], now: Date, to center: HubNoticeCenter) {
        for action in actions {
            switch action {
            case .cancel(let kind):
                center.removeNotices(ids: [kind.identifier])
            case .schedule(let n):
                center.removeNotices(ids: [n.kind.identifier])
                center.addNotice(id: n.kind.identifier, title: n.title, body: n.body,
                                 after: max(1, n.fireAt.timeIntervalSince(now)))
            }
        }
    }
}

enum HubNoticeRefresher {
    /// One refresh: plan, apply, and return the memory to store. When the app may not show
    /// notifications (`canNotify` false: denied, or the prompt not answered yet) nothing is applied and
    /// the memory comes back UNCHANGED, so nothing is recorded as "sent" while it couldn't be seen; the
    /// refresh after permission is granted delivers it (T4.3 review finding 1).
    static func refresh(_ inputs: HubNoticeInputs, memory: HubNoticeMemory, canNotify: Bool,
                        center: HubNoticeCenter) -> HubNoticeMemory {
        guard canNotify else { return memory }
        let (actions, next) = HubNoticePlanner.plan(inputs, memory: memory)
        HubNoticeApplier.apply(actions, now: inputs.now, to: center)
        return next
    }
}
