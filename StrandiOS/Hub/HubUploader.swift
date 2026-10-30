// Fork-only (phone-hub). The iOS side of the uploader: reads NOOP's store through the app's Repository
// and LiveState, runs `HubUploadEngine` inside a `beginBackgroundTask` window, and is called from the two
// hook points (a completed strap backfill in AppModel, and scenePhase == .active in StrandiOSApp).
// All decisions (what to send, when, what the ack moves) are in Core/ and unit-tested there.
#if os(iOS)
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
        HubNotifications.refresh()
        start(.foreground)
    }

    /// Hook: a strap backfill finished (AppModel.refreshAfterCompletedBackfill). The Bluetooth wake that
    /// delivered it is the only background driver under SideStore.
    static func backfillFinished() { start(.backfill) }

    static func start(_ trigger: HubTrigger) { Task { @MainActor in _ = await run(trigger) } }

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
        let work = Task { await engine.run(trigger, shouldContinue: { !flag.isSet && Date() < deadline }) }
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

/// HubDataSource over NOOP's Repository. Reads the same id union the dashboard reads for HR (active strap
/// + canonical history), the active strap for events and battery (they belong to the strap that sent
/// them), and the dashboard's merged daily rows and sleep sessions. Only contract columns are copied out.
@MainActor
final class HubRepositorySource: HubDataSource {
    private var model: AppModel? { AppModel.shared }

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
        let sleep = model.repo.sleeps.map {
            HubSleepInput(startTs: $0.startTs, endTs: $0.endTs, efficiency: $0.efficiency, restingHr: $0.restingHr,
                          avgHrv: $0.avgHrv, startTsAdjusted: $0.startTsAdjusted, userEdited: $0.userEdited)
        }
        return HubRunContext(device: device, timeZone: tz, daily: daily, sleep: sleep,
                             steps: HubBatchBuilder.steps(steps))
    }

    func hrSamples(from: Int, to: Int) async -> [HubHRSampleInput] {
        await hrUnion(from: from, to: to, limit: 200_000)
    }

    func events(from: Int, to: Int) async -> [HubEventInput] {
        guard let a = await activeStore() else { return [] }
        let (store, id) = a
        let rows = (try? await store.events(deviceId: id, from: from, to: to, limit: 100_000)) ?? []
        return rows.filter { HubBatchBuilder.eventWhitelist.contains($0.kind) }.map { HubEventInput(ts: $0.ts, kind: $0.kind) }
    }

    func battery(from: Int, to: Int) async -> [HubBatteryInput] {
        guard let a = await activeStore() else { return [] }
        let (store, id) = a
        // NOOP's battery read projects ts, soc, mv; `charging` stays null (charging on/off travel as events).
        let rows = (try? await store.batterySamples(deviceId: id, from: from, to: to, limit: 100_000)) ?? []
        return rows.map { HubBatteryInput(ts: $0.ts, soc: $0.soc, mv: $0.mv, charging: $0.charging) }
    }

    func firstTs(_ s: HubStream, from: Int, to: Int) async -> Int? {
        switch s {
        case .hr_minute:
            return await hrUnion(from: from, to: to, limit: 1).first?.ts
        case .battery:
            return await battery(from: from, to: to).first?.ts
        case .events:
            // Page through non-whitelisted kinds (BLE link events etc.) to the first sendable one.
            guard let a = await activeStore() else { return nil }
            let (store, id) = a
            var lo = from
            while lo <= to {
                let page = (try? await store.events(deviceId: id, from: lo, to: to, limit: 1_000)) ?? []
                if let hit = page.first(where: { HubBatchBuilder.eventWhitelist.contains($0.kind) }) { return hit.ts }
                guard page.count == 1_000, let last = page.last?.ts else { return nil }
                lo = last + 1
            }
            return nil
        }
    }

    func fingerprints(_ s: HubStream, ranges: [ClosedRange<Int>]) async -> [HubFingerprint] {
        guard let lo = ranges.map(\.lowerBound).min(), let hi = ranges.map(\.upperBound).max() else { return [] }
        // One read over the whole span, bucketed per range: same rows the uploader would send.
        let ts: [Int]
        switch s {
        case .hr_minute: ts = await hrUnion(from: lo, to: hi, limit: 400_000).map(\.ts)
        case .events: ts = await events(from: lo, to: hi).map(\.ts)
        case .battery: ts = await battery(from: lo, to: hi).map(\.ts)
        }
        return ranges.map { r in
            var c = 0, m = 0
            for t in ts where r.contains(t) { c += 1; m = max(m, t) }
            return HubFingerprint(count: c, maxTs: m)
        }
    }

    // MARK: helpers

    private func activeStore() async -> (WhoopStore, String)? {
        guard let repo = model?.repo, let store = await repo.storeHandle() else { return nil }
        return (store, repo.deviceId)
    }

    /// HR over the dashboard's imported read union (active strap first, canonical history), measured ∪
    /// PPG-derived per id (WhoopStore.hrSamples), deduped by second with the active strap winning.
    private func hrUnion(from: Int, to: Int, limit: Int) async -> [HubHRSampleInput] {
        guard let repo = model?.repo, let store = await repo.storeHandle() else { return [] }
        var byTs: [Int: Int] = [:]
        for id in repo.importedReadIds {
            for s in (try? await store.hrSamples(deviceId: id, from: from, to: to, limit: limit)) ?? [] where byTs[s.ts] == nil {
                byTs[s.ts] = s.bpm
            }
        }
        let sorted = byTs.keys.sorted()
        return (limit < sorted.count ? Array(sorted.prefix(limit)) : sorted).map { HubHRSampleInput(ts: $0, bpm: byTs[$0]!) }
    }
}
#endif
