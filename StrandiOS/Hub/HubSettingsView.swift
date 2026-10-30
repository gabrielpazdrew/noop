// Fork-only (phone-hub). The Health Hub settings screen, reached from More › Data › Health Hub.
#if os(iOS)
import SwiftUI
import StrandDesign

/// URL, token, on/off, last upload, "Upload now", renewal estimate. The token is pasted once,
/// saved to the Keychain, and never displayed again (only "saved" / "not set").
struct HubSettingsView: View {
    private let state = HubState.shared

    @State private var urlText = ""
    @State private var urlError = false
    @State private var tokenText = ""
    @State private var tokenMessage: String? = nil
    @State private var hasToken = false
    @State private var enabled = false
    @State private var uploading = false
    @State private var tick = 0 // bumped on HubState.didChange to re-read status

    var body: some View {
        ScreenScaffold(title: "Health Hub",
                       subtitle: "Send your strap data to your own private hub. Off by default.") {
            connectionCard
            statusCard
            renewalCard
        }
        .onAppear(perform: load)
        .onReceive(NotificationCenter.default.publisher(for: HubState.didChange).receive(on: RunLoop.main)) { _ in tick += 1 }
    }

    // MARK: cards

    private var connectionCard: some View {
        StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                header("Connection", icon: "network")
                Toggle(isOn: $enabled) {
                    Text("Upload to hub").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
                .onChange(of: enabled) { _, on in
                    // load() copying the stored value in is not a user switch: no prompts, no rewrite.
                    guard on != state.enabled else { return }
                    state.enabled = on
                    if on { HubNotifications.requestAuthorization(); HubSteps.requestAuthorizationIfNeeded() }
                    HubNotifications.refresh(state: state)
                }

                Text("Hub address").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                TextField("https://…", text: $urlText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .font(StrandFont.body)
                    .onSubmit(saveURL)
                if urlError {
                    Text("Needs a full https:// address.").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Button("Save address", action: saveURL).buttonStyle(NoopButtonStyle(.secondary))

                Text("Phone token").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                Text(hasToken ? "Saved in this iPhone's Keychain. Paste a new one to replace it." : "Not set.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                SecureField("Paste token", text: $tokenText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(StrandFont.body)
                    .onSubmit(saveToken)
                HStack(spacing: 10) {
                    Button("Save token", action: saveToken)
                        .buttonStyle(NoopButtonStyle(.secondary))
                        .disabled(tokenText.isEmpty)
                    if hasToken {
                        Button("Remove token") {
                            HubKeychain.deleteToken()
                            hasToken = HubKeychain.hasToken
                            tokenMessage = hasToken ? "Couldn't remove the token." : "Token removed."
                        }
                        .buttonStyle(NoopButtonStyle(.tertiary))
                    }
                }
                if let tokenMessage {
                    Text(tokenMessage).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private var statusCard: some View {
        let _ = tick
        return StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                header("Last upload", icon: "arrow.up.circle")
                Text(lastUploadLine).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                if let since = state.failingSince {
                    Text("Failing since \(since.formatted(date: .abbreviated, time: .shortened)).")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                if state.locked {
                    Text("The hub is locked and refusing uploads. Unlock it from the Mac.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                if state.openAlerts > 0 {
                    Text("Open hub alerts: \(state.openAlerts)")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
                Button {
                    guard let hook = HubHooks.uploadNow else { return }
                    uploading = true
                    Task {
                        await hook()
                        uploading = false
                        HubNotifications.refresh(state: state)
                    }
                } label: {
                    Text(uploading ? "Uploading…" : "Upload now")
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(!canUpload || uploading)
                if HubHooks.uploadNow == nil {
                    Text("The uploader isn't part of this build yet.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private var renewalCard: some View {
        let _ = tick
        let embedded = SigningInfo.embeddedExpirationDate()
        let estimate = HubNoticePlanner.renewalEstimate(server: state.serverRenewalEstimate, embedded: embedded)
        return StrandCard(padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                header("App signing", icon: "calendar.badge.clock")
                Text(estimate.map { "Runs out around \($0.formatted(date: .abbreviated, time: .shortened))." }
                     ?? "Expiry unknown (no signing profile found).")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Text("You get a reminder 3 days before. Refresh NOOP in SideStore to reset it.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
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

    private var canUpload: Bool {
        HubHooks.uploadNow != nil && enabled && state.hubURL != nil && hasToken
    }

    private var lastUploadLine: String {
        guard let at = state.lastUploadAt else { return "Never." }
        let when = at.formatted(date: .abbreviated, time: .shortened)
        return "\(when): \(state.lastUploadResult ?? "unknown")"
    }

    private func load() {
        urlText = state.hubURLString ?? ""
        enabled = state.enabled
        hasToken = HubKeychain.hasToken
        HubNotifications.refresh(state: state)
    }

    private func saveURL() {
        if urlText.trimmingCharacters(in: .whitespaces).isEmpty {
            state.hubURLString = nil
            urlError = false
        } else if let url = HubState.validatedURL(urlText) {
            state.hubURLString = url.absoluteString
            urlText = url.absoluteString
            urlError = false
        } else {
            urlError = true
        }
    }

    private func saveToken() {
        let ok = HubKeychain.saveToken(tokenText)
        tokenText = "" // never kept in memory or shown after a save attempt
        hasToken = HubKeychain.hasToken
        tokenMessage = ok ? "Token saved." : "That doesn't look like a token (empty or has spaces), or the Keychain refused it."
    }
}
#endif
