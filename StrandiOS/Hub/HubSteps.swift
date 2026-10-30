// Fork-only (phone-hub). CoreMotion adapter for the hub's daily phone step totals; the bucketing and
// permission logic is pure and lives in Core/HubStepsCore.swift.
import Foundation
#if os(iOS)
import CoreMotion
#endif

enum HubSteps {
    #if os(iOS)
    private static let pedometer = CMPedometer()

    /// CMPedometer as a `HubPedometerSource`.
    struct CoreMotionSource: HubPedometerSource {
        var isStepCountingAvailable: Bool { CMPedometer.isStepCountingAvailable() }
        var authorization: HubStepsAuthorization {
            switch CMPedometer.authorizationStatus() {
            case .authorized: return .authorized
            case .denied: return .denied
            case .restricted: return .restricted
            case .notDetermined: return .notDetermined
            @unknown default: return .denied
            }
        }
        func query(from start: Date, to end: Date, completion: @escaping (HubPedometerTotals?) -> Void) {
            HubSteps.pedometer.queryPedometerData(from: start, to: end) { data, error in
                guard let data, error == nil else { completion(nil); return }
                completion(HubPedometerTotals(steps: data.numberOfSteps.intValue,
                                              distanceM: data.distance?.doubleValue,
                                              floorsAscended: data.floorsAscended?.intValue))
            }
        }
    }

    /// Daily totals for the last 7 local days (today so far + 6 before), cut at local midnight in the
    /// device's current time zone. Never prompts: when Motion access hasn't been decided yet the result
    /// is `.notDetermined` with no rows. Returns within `HubStepsCore.defaultDeadline` (5 s) even if
    /// CoreMotion never answers; days without an answer are left out. T4.1 calls this on every upload.
    static func snapshot(now: Date = Date(),
                         calendar: Calendar = HubStepsCore.gregorian(in: .current)) async -> HubStepsSnapshot {
        await withCheckedContinuation { (cont: CheckedContinuation<HubStepsSnapshot, Never>) in
            HubStepsCore.read(source: CoreMotionSource(), now: now, calendar: calendar) { cont.resume(returning: $0) }
        }
    }

    /// Raises the Motion & Fitness prompt if it has never been answered. Called ONLY when the user turns
    /// the hub on (CMPedometer has no explicit request API: a one-minute query raises the prompt).
    static func requestAuthorizationIfNeeded() {
        guard CMPedometer.isStepCountingAvailable(),
              CMPedometer.authorizationStatus() == .notDetermined else { return }
        let now = Date()
        pedometer.queryPedometerData(from: now.addingTimeInterval(-60), to: now) { _, _ in }
    }
    #else
    static func snapshot(now: Date = Date(),
                         calendar: Calendar = HubStepsCore.gregorian(in: .current)) async -> HubStepsSnapshot {
        HubStepsSnapshot(status: .unavailable, days: [], timeZone: calendar.timeZone.identifier)
    }
    static func requestAuthorizationIfNeeded() {}
    #endif
}
