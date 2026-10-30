// Fork-only (phone-hub). The iOS side of the uploader: reads NOOP's store through the app's Repository
// and LiveState, runs `HubUploadEngine` inside a `beginBackgroundTask` window, and is called from the two
// hook points (a completed strap backfill in AppModel, and scenePhase == .active in StrandiOSApp).
// All decisions (what to send, when, what the ack moves) are in Core/ and unit-tested there.
#if os(iOS)
import Combine
import Foundation
import UIKit
import WhoopStore
import WhoopProtocol

@MainActor
enum HubUploader {
    private static let source = HubRepositorySource()
    static let engine = HubUploadEngine(source: source, client: HubClient(), state: .shared,
                                        marks: HubWatermarkStore(),
                                        afterAttempt: { HubNotifications.refresh() })

    /// Hook: the app came to the foreground. Installs "Upload now", re-plans the hub notifications (the
    /// renewal reminder must not depend on opening the Health Hub screen), and uploads if due.
    static func sceneBecameActive() {
        HubHooks.uploadNow = { _ = await HubUploader.run(.manual) }
        watchBackfilling()
        HubNotifications.refresh()
        start(.foreground)
    }

    /// Hook: a strap backfill finished (AppModel.refreshAfterCompletedBackfill). The Bluetooth wake that
    /// delivered it is the only background driver under SideStore.
    static func backfillFinished() { start(.backfill) }

    static func start(_ trigger: HubTrigger) {
        watchBackfilling()
        Task { @MainActor in _ = await run(trigger) }
    }

    /// When `live.backfilling` last turned off (in memory): HubHoldPolicy's 120 s quiet window covers the gap
    /// between two passes of a segmented offload. Installed on the first hook call, foreground or background.
    private(set) static var lastBackfillingEndedAt: Int?
    private static var backfillingWatch: AnyCancellable?

    static func watchBackfilling() {
        guard backfillingWatch == nil, let live = AppModel.shared?.live else { return }
        backfillingWatch = live.$backfilling.removeDuplicates().dropFirst().sink { on in
            if !on { HubUploader.lastBackfillingEndedAt = Int(Date().timeIntervalSince1970) }
        }
    }

    /// One run inside a background-task window. The expiration handler cancels the run: the in-flight
    /// request is cancelled, its rows stay unacked, and nothing advances.
    static func run(_ trigger: HubTrigger) async -> HubRunOutcome {
        let state = HubState.shared
        // Nothing runs (not even a background task) while the hub is off or unconfigured.
        guard state.enabled, state.hubURL != nil, HubKeychain.hasToken else { return .skipped("hub off or unconfigured") }

        let flag = HubCancelFlag()
        let box = HubTaskBox()
        let app = UIApplication.shared
        box.bgID = app.beginBackgroundTask(withName: "noop.hub.upload") {
            // iOS calls the expiration handler on the main thread.
            MainActor.assumeIsolated {
                flag.set()
                box.work?.cancel()
                box.end()
            }
        }
        // Foreground: effectively unlimited. Background: stop starting new requests 8 s before iOS's deadline.
        let remaining = app.backgroundTimeRemaining
        let deadline = remaining > 1e6 ? Date.distantFuture : Date().addingTimeInterval(remaining - 8)
        // For a backfill: when the offload's data landed, so the run isn't throttled by a foreground run
        // that started before it (that foreground is what kicked the offload off).
        let landed = AppModel.shared?.live.lastSyncedAt.map { Int($0) }
        let work = Task {
            await engine.run(trigger, dataLandedAt: trigger == .backfill ? landed : nil,
                             shouldContinue: { !flag.isSet && Date() < deadline })
        }
        box.work = work
        let outcome = await work.value
        box.end()
        return outcome
    }
}

/// Set once by the expiration handler; read from the engine's actor.
final class HubCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@MainActor
final class HubTaskBox {
    var bgID: UIBackgroundTaskIdentifier = .invalid
    var work: Task<HubRunOutcome, Never>?
    func end() {
        guard bgID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgID)
        bgID = .invalid
    }
}

/// A store read that couldn't be answered (store not open, or the read threw). The run fails; nothing
/// is marked as sent.
struct HubStoreReadError: Error {}

/// HubDataSource over NOOP's Repository. Reads the same id union the dashboard reads for HR (active strap
/// + canonical history), the active strap for events and battery (they belong to the strap that sent
/// them), and the dashboard's merged daily rows and sleep sessions. Only contract columns are copied out.
/// Store reads happen on the store's own actor; merging and bucketing run off the main actor.
@MainActor
final class HubRepositorySource: HubDataSource {
    private var model: AppModel? { AppModel.shared }
    /// NOOP's learned habitual midsleep (the Sleep tab's main-night pick uses it), cached for an hour.
    private var midsleep: (value: Int?, at: Date)?

    func context(now: Int) async -> HubRunContext? {
        guard let model, await model.repo.storeHandle() != nil else { return nil }
        let steps = await HubSteps.snapshot()
        let tz = TimeZone(identifier: steps.timeZone) ?? .current
        let info = Bundle.main.infoDictionary
        var battery = model.live.batteryPct
        if battery == nil { battery = await model.repo.latestBattery()?.soc }
        let device = HubDevice(appVersion: info?["CFBundleShortVersionString"] as? String ?? "unknown",
                               build: info?["CFBundleVersion"] as? String ?? "unknown",
                               bandFw: model.live.strapFirmware,
                               bandBattery: battery,
                               embeddedExpiry: SigningInfo.embeddedExpirationDate().map { Int($0.timeIntervalSince1970) },
                               tz: tz.identifier,
                               stepsStatus: steps.status.rawValue)
        let daily = model.repo.days.map {
            HubDailyInput(day: $0.day, recovery: $0.recovery, strain: $0.strain, restingHr: $0.restingHr,
                          avgHrv: $0.avgHrv, avgSdnn: $0.avgSdnn, respRateBpm: $0.respRateBpm,
                          skinTempDevC: $0.skinTempDevC, totalSleepMin: $0.totalSleepMin,
                          efficiency: $0.efficiency, disturbances: $0.disturbances,
                          exerciseCount: $0.exerciseCount, steps: $0.steps, activeKcalEst: $0.activeKcalEst)
        }
        let sleep = await sleepInputs(model.repo.sleeps, tz: tz)
        return HubRunContext(device: device, timeZone: tz, daily: daily, sleep: sleep,
                             steps: HubBatchBuilder.steps(steps),
                             // R23 completeness: only a loaded, non-empty list may define a window.
                             sleepLoaded: model.repo.loaded && !model.repo.sleeps.isEmpty,
                             backfilling: model.live.backfilling,
                             historyPendingSync: model.live.historyPendingSync,
                             lastBackfillingEndedAt: HubUploader.lastBackfillingEndedAt)
    }

    /// Sleep sessions with NOOP's own asleep minutes (decoded from the stored stages ON THE PHONE; only the
    /// total leaves it) and NOOP's own main-night grouping per local end day (the Sleep tab's rule).
    private func sleepInputs(_ sessions: [CachedSleepSession], tz: TimeZone) async -> [HubSleepInput] {
        if midsleep == nil || Date().timeIntervalSince(midsleep!.at) > 3_600 {
            midsleep = (await model?.repo.habitualMidsleepSec(), Date())
        }
        let habitual = midsleep?.value
        var mainStarts = Set<Int>()
        let byEndDay = Dictionary(grouping: sessions) { HubBatchBuilder.localDay($0.endTs, tz) }
        for (_, day) in byEndDay {
            for s in SleepView.mainNightGroup(day, habitualMidsleepSec: habitual) { mainStarts.insert(s.startTs) }
        }
        return sessions.map { s in
            let asleep = SleepView.decodeStages(s.stagesJSON)?.asleep
                ?? SleepView.decodeSegments(s.stagesJSON, sessionStart: s.effectiveStartTs)?.stages.asleep
            return HubSleepInput(startTs: s.startTs, endTs: s.endTs, efficiency: s.efficiency, restingHr: s.restingHr,
                                 avgHrv: s.avgHrv, startTsAdjusted: s.startTsAdjusted, userEdited: s.userEdited,
                                 asleepMin: asleep, isMain: mainStarts.contains(s.startTs))
        }
    }

    func hrSamples(from: Int, to: Int) async throws -> [HubHRSampleInput] {
        try await hrUnion(from: from, to: to, limit: 200_000)
    }

    func events(from: Int, to: Int) async throws -> [HubEventInput] {
        let (store, id) = try await activeStore()
        let rows = try await store.events(deviceId: id, from: from, to: to, limit: 100_000)
        return rows.filter { HubBatchBuilder.eventWhitelist.contains($0.kind) }.map { HubEventInput(ts: $0.ts, kind: $0.kind) }
    }

    func battery(from: Int, to: Int) async throws -> [HubBatteryInput] {
        let (store, id) = try await activeStore()
        // NOOP's battery read projects ts, soc, mv; `charging` stays null (charging on/off travel as events).
        let rows = try await store.batterySamples(deviceId: id, from: from, to: to, limit: 100_000)
        return rows.map { HubBatteryInput(ts: $0.ts, soc: $0.soc, mv: $0.mv, charging: $0.charging) }
    }

    func firstTs(_ s: HubStream, from: Int, to: Int) async throws -> Int? {
        switch s {
        case .hr_minute:
            return try await hrUnion(from: from, to: to, limit: 1).first?.ts
        case .battery:
            let (store, id) = try await activeStore()
            return try await store.batterySamples(deviceId: id, from: from, to: to, limit: 1).first?.ts
        case .events:
            // Page through non-whitelisted kinds (BLE link events etc.) to the first sendable one.
            let (store, id) = try await activeStore()
            var lo = from
            while lo <= to {
                let page = try await store.events(deviceId: id, from: lo, to: to, limit: 1_000)
                if let hit = page.first(where: { HubBatchBuilder.eventWhitelist.contains($0.kind) }) { return hit.ts }
                guard page.count == 1_000, let last = page.last?.ts else { return nil }
                lo = last + 1
            }
            return nil
        }
    }

    func fingerprints(_ s: HubStream, ranges: [ClosedRange<Int>]) async throws -> [HubFingerprint] {
        guard let lo = ranges.map(\.lowerBound).min(), let hi = ranges.map(\.upperBound).max() else { return [] }
        // One read over the whole span, bucketed per range: same rows the uploader would send.
        let ts: [Int]
        switch s {
        case .hr_minute: ts = try await hrUnion(from: lo, to: hi, limit: 400_000).map(\.ts)
        case .events: ts = try await events(from: lo, to: hi).map(\.ts)
        case .battery: ts = try await battery(from: lo, to: hi).map(\.ts)
        }
        return await Task.detached(priority: .utility) { Self.bucket(ts, ranges) }.value
    }

    // MARK: helpers

    nonisolated static func bucket(_ ts: [Int], _ ranges: [ClosedRange<Int>]) -> [HubFingerprint] {
        let sorted = ts.sorted()
        return ranges.map { r in
            // Binary search for the first ts >= lowerBound, then count through upperBound.
            var lo = 0, hi = sorted.count
            while lo < hi { let mid = (lo + hi) / 2; if sorted[mid] < r.lowerBound { lo = mid + 1 } else { hi = mid } }
            var c = 0, m = 0, i = lo
            while i < sorted.count && sorted[i] <= r.upperBound { c += 1; m = sorted[i]; i += 1 }
            return HubFingerprint(count: c, maxTs: m)
        }
    }

    nonisolated static func mergeHR(_ lists: [[HRSample]], limit: Int) -> [HubHRSampleInput] {
        var byTs: [Int: Int] = [:]
        for list in lists { for s in list where byTs[s.ts] == nil { byTs[s.ts] = s.bpm } }   // active strap first
        let sorted = byTs.keys.sorted()
        return (limit < sorted.count ? Array(sorted.prefix(limit)) : sorted).map { HubHRSampleInput(ts: $0, bpm: byTs[$0]!) }
    }

    private func activeStore() async throws -> (WhoopStore, String) {
        guard let repo = model?.repo, let store = await repo.storeHandle() else { throw HubStoreReadError() }
        return (store, repo.deviceId)
    }

    /// HR over the dashboard's imported read union (active strap first, canonical history), measured ∪
    /// PPG-derived per id (WhoopStore.hrSamples), deduped by second with the active strap winning.
    private func hrUnion(from: Int, to: Int, limit: Int) async throws -> [HubHRSampleInput] {
        guard let repo = model?.repo, let store = await repo.storeHandle() else { throw HubStoreReadError() }
        var lists: [[HRSample]] = []
        for id in repo.importedReadIds {
            lists.append(try await store.hrSamples(deviceId: id, from: from, to: to, limit: limit))
        }
        return await Task.detached(priority: .utility) { Self.mergeHR(lists, limit: limit) }.value
    }
}
#endif
