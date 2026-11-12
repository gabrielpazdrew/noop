// Fork-only (phone-hub, wake). PLAN-WAKE-PHONE T6: the Wake Alarm screen, reached from More › App › Wake Alarm.
//
// The switch, "Skip tomorrow", "Stop now" while a run is live, how a run starts, and the last runs.
// Nothing here can start a run or buzz the band: there is no test button and no time picker. A run
// starts only from the "Start Wake Alarm" Shortcuts action (WakeAlarmRunner.trigger).
#if os(iOS)
import SwiftUI
import StrandDesign

struct WakeAlarmSettingsView: View {
    private var runner: WakeAlarmRunner { .shared }
    private let calendar = Calendar.current

    @State private var enabled = true
    @State private var skipDay: String? = nil
    @State private var revision = 0 // bumped after a tap to re-read the run state

    var body: some View {
        ScreenScaffold(title: "Wake Alarm",
                       subtitle: "The band buzzes until your heart rate shows you're up. On by default.") {
            settingsCard
            // Re-reads the live run and the records every few seconds while the screen is open.
            // Display only: nothing in this refresh can start a run or buzz.
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                runsCard
            }
        }
        .onAppear(perform: load)
    }

    // MARK: cards

    private var settingsCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                header("Wake alarm", icon: "alarm.fill")
                Toggle(isOn: $enabled) {
                    Text("Wake alarm").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .onChange(of: enabled) { _, on in
                    var s = WakeAlarmSettings(defaults: WakeAlarmRunner.defaults)
                    // load() copying the stored value in is not a user switch.
                    guard on != s.enabled else { return }
                    s.enabled = on
                    if !on { runner.stopNow() }
                    revision += 1
                }

                if let skipDay {
                    Text(WakeScreenText.skipActiveLine(day: skipDay, calendar: calendar))
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    Button("Cancel skip") { setSkip(nil) }
                        .buttonStyle(NoopButtonStyle(.secondary))
                } else {
                    let target = WakeAlarmSettings.skipTargetDay(now: Date(), calendar: calendar)
                    Button(WakeScreenText.skipButtonTitle(target: target, calendar: calendar)) { setSkip(target) }
                        .buttonStyle(NoopButtonStyle(.secondary))
                }

                Text("Starts only from your iPhone's Sleep Schedule wake-up alarm: a Shortcuts \"Waking Up\" automation runs the action \"Start Wake Alarm\".")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var runsCard: some View {
        let _ = revision
        let runs = WakeScreenText.recentRuns(WakeRunLog(defaults: WakeAlarmRunner.defaults).records)
        return StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                header("Runs", icon: "list.bullet")
                if runner.isRunning {
                    Text("A wake run is going now.").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    Button("Stop now") {
                        runner.stopNow()
                        revision += 1
                    }
                    .buttonStyle(NoopButtonStyle(.destructive))
                }
                if runs.isEmpty {
                    Text("No runs yet.").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(WakeScreenText.runTitle(run, calendar: calendar))
                            .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                        Text(WakeScreenText.runDetail(run))
                            .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: helpers

    private func header(_ title: LocalizedStringKey, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(StrandPalette.accent).accessibilityHidden(true)
            Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
        }
    }

    private func load() {
        var s = WakeAlarmSettings(defaults: WakeAlarmRunner.defaults)
        s.clearSkipIfPassed(now: Date(), calendar: calendar)
        enabled = s.enabled
        skipDay = s.skipDay
        revision += 1
    }

    private func setSkip(_ day: String?) {
        var s = WakeAlarmSettings(defaults: WakeAlarmRunner.defaults)
        s.skipDay = day
        skipDay = s.skipDay
    }
}

#Preview {
    NavigationStack { WakeAlarmSettingsView() }
}
#endif
