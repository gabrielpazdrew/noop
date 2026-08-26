#if os(macOS)
import AppKit
import Foundation

/// Fork-only (trusted-build branch): two small macOS doors that need no App Intents and no
/// code-signing identity. Wired in via `@NSApplicationDelegateAdaptor` in StrandApp.swift.
///
/// 1. **`noop://buzz[?loops=N]` URL handler.** `open "noop://buzz"` from a shell / launchd / SSH
///    session buzzes the bonded strap through the same acknowledged one-shot routine the Live
///    "Buzz strap" button and the Buzz Strap App Intent use (`AppModel.buzzStrapOnce()`). App
///    Intents cannot be dispatched to an ad-hoc-signed build ("Shortcuts couldn't communicate
///    with the app"); a URL scheme goes through LaunchServices and has no such requirement. The
///    handler is registered in `applicationWillFinishLaunching` — registering in *DidFinish*
///    drops the URL that launched the app. Guards mirror `BuzzStrapIntent`: live model present
///    AND `live.bonded`, else the request is logged and ignored. `loops` (1…3, default 1)
///    repeats the one-shot 2 s apart. Any other `noop://…` URL is ignored here (the Oura OAuth
///    callback is consumed inside ASWebAuthenticationSession and never reaches this handler).
///
/// 2. **Dynamic Dock icon.** The app ships `LSUIElement=true` (menu-bar-only: no Dock icon, no
///    Cmd-Tab entry at launch). While a real document window is key the activation policy is
///    raised to `.regular` (Dock icon + Cmd-Tab), and dropped back to `.accessory` when the last
///    real window closes. MenuBarExtra panels / status-bar windows are not "real" windows.
@MainActor
final class MacAppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowDidBecomeKey(_:)),
                       name: NSWindow.didBecomeKeyNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowWillClose(_:)),
                       name: NSWindow.willCloseNotification, object: nil)
    }

    // MARK: - noop://buzz

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: raw),
              url.scheme?.lowercased() == "noop",
              url.host?.lowercased() == "buzz" else { return }
        var loops = 1
        if let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "loops" })?.value,
           let n = Int(value) {
            loops = max(1, min(3, n))
        }
        guard let model = AppModel.shared else { return }   // no live model: nothing to buzz
        guard model.live.bonded else {
            model.ble.state.append(log: "[\(Self.stamp())] URL noop://buzz ignored: strap not bonded")
            return
        }
        model.ble.state.append(log: "[\(Self.stamp())] URL noop://buzz → buzzStrapOnce ×\(loops)")
        for i in 0..<loops {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 2.0) { [weak model] in
                guard let model, model.live.bonded else { return }
                model.buzzStrapOnce()
            }
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()
    private static func stamp() -> String { stampFormatter.string(from: Date()) }

    // MARK: - Dock icon follows real windows

    /// A window the user would expect in the Dock / Cmd-Tab: the SwiftUI WindowGroup shell.
    /// Excludes NSPanel (MenuBarExtra `.window` popover, sheets' helpers), status-bar windows,
    /// and anything not at normal level or without a title bar.
    private static func isRealWindow(_ w: NSWindow) -> Bool {
        if w is NSPanel { return false }
        if w.level != .normal { return false }
        if !w.styleMask.contains(.titled) { return false }
        let cls = String(describing: type(of: w))
        if cls.contains("StatusBar") || cls.contains("MenuBarExtra") || cls.contains("Popover") { return false }
        return true
    }

    @objc private func windowDidBecomeKey(_ n: Notification) {
        guard let w = n.object as? NSWindow, Self.isRealWindow(w) else { return }
        if NSApp.activationPolicy() != .regular {
            _ = NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func windowWillClose(_ n: Notification) {
        guard let closing = n.object as? NSWindow, Self.isRealWindow(closing) else { return }
        // The closing window is still in NSApp.windows during willClose — decide on the next turn.
        DispatchQueue.main.async {
            let remaining = NSApp.windows.filter { $0 !== closing && $0.isVisible && Self.isRealWindow($0) }
            if remaining.isEmpty, NSApp.activationPolicy() != .accessory {
                _ = NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
#endif
