// Fork-only (phone-hub). Foundation-only: compiled into NOOPiOS AND the NOOPiOSHubTests bundle.
//
// Which write errors count as failed wake buzzes. BLEManager reports any failed acknowledged write on the
// command characteristic (a wake buzz is two of them; sync acks and bond writes use it too), with no way
// to say which command failed. So a buzz owns a 3 s window after it was sent: the first error inside the
// window charges that buzz, once; later errors for the same buzz are ignored; a buzz whose window passes
// with no error counts as written OK. At most one failure per buzz, never more.
import Foundation

struct WakeBuzzLedger: Equatable {
    static let window: TimeInterval = 3

    /// Send times of buzzes still inside their window with no verdict, oldest first.
    private(set) var pending: [Date] = []

    mutating func sent(at: Date) { pending.append(at) }

    /// A write error at `at`: charges the oldest pending buzz sent at or before `at` and no more than the
    /// window before it. True when a buzz was charged (that buzz then gets no other verdict).
    mutating func writeError(at: Date) -> Bool {
        guard let i = pending.firstIndex(where: { at >= $0 && at.timeIntervalSince($0) <= Self.window }) else {
            return false
        }
        pending.remove(at: i)
        return true
    }

    /// Buzzes whose window has passed at `now` with no error: removed, and their count returned (each is
    /// one `buzzResult(ok: true)`). A clock that went back expires nothing.
    mutating func expire(now: Date) -> Int {
        let before = pending.count
        pending.removeAll { now.timeIntervalSince($0) > Self.window }
        return before - pending.count
    }
}
