import Foundation

/// The family's claim on this Mac's shared input hardware: the screen, the keyboard, the microphone
/// and Speech. There is one of each per machine, so two UI checks on one Mac spoil each other, and
/// the victim's failures land on whichever step waits on input and read exactly like broken code.
///
/// **Why this lives in a shared module rather than in each app's UI test.**
///
/// The lock is otherwise only etiquette. A script that never asks for it simply runs, and no test of
/// the locking code can see that, because every such test has a cooperating participant by
/// construction. Seen in practice: a lock held *legitimately* by a live run, sitting alongside four
/// other Mac UI checks driving the same screen in the same moment, none of which had asked for it,
/// while every lock property passed throughout. A live holder rules out a stale lock as the cause;
/// those were simply runs that never called the helper.
///
/// This file is copied wholesale into the public Glyph Jot and Glyph Time repositories by their
/// publish scripts, so it carries no machine names, hostnames, usernames or session names.
///
/// An app is the only place that catches a caller who does not cooperate, because every Mac UI check
/// drives an app. There are five separate copies of `UITest.swift` across the family, so writing the
/// refusal in each would mean five implementations of the one rule that has to be identical
/// everywhere. It is written once here instead, in the module every Glyph Mac app already depends on,
/// and each app's UI test calls it as its first act.
///
/// **The contract.**
///
/// `GLYPH_INPUT_LOCK_PID` is exported by the shell helper that takes the lock (`take_input_lock` in
/// `scripts/input-lock.sh`) and by any caller that already holds it. The holder file must still name
/// that pid, so a lock that was dropped and retaken by someone else does not count as ours, which is
/// the case seen in practice. A lock obtained by reclaiming a dead holder's must write its
/// own holder before the app looks, or the app will refuse the very run that just legitimately took
/// it.
///
/// **Exit status 2 means "this Mac's input hardware was busy", family-wide**, so a dispatcher can
/// tell that apart from any other failure. Omega's and Glyph Time's shell helpers already exit 2 on
/// contention; CRM's exits 3 and is the odd one out.
public enum GlyphScreenLock {
    /// Shared by every Glyph app's checks. Do not rename it: seven scripts take it by this name.
    public static let directory = "/tmp/glyph-mac-ui.lock.d"

    /// The family's exit status for "the input hardware is held by someone else".
    public static let busyStatus: Int32 = 2

    /// The pid a holder file names, or nil when there is none to find.
    ///
    /// Parses the first line and takes the field after the literal `pid`, rather than a fixed field
    /// position. Three holder formats are in use across the family and two of them put the pid in
    /// field 3 while Omega's puts the word "on" there, so a positional parser silently reads the
    /// wrong field against another app's lock. Pure, so it can be checked without exiting.
    public static func holdingPid(_ holder: String) -> String? {
        guard let first = holder.split(separator: "\n").first else { return nil }
        let fields = first.split(separator: " ").map(String.init)
        guard let i = fields.firstIndex(of: "pid"), i + 1 < fields.count else { return nil }
        let pid = fields[i + 1]
        return pid.isEmpty ? nil : pid
    }

    /// Whether the run that claims `claimed` is the one the holder names. Pure, for the same reason.
    public static func heldByThisRun(holder: String, claimed: String?) -> Bool {
        guard let claimed, !claimed.isEmpty, let pid = holdingPid(holder) else { return false }
        return pid == claimed
    }

    /// The holder file's first line, or an empty string when the lock is free.
    public static func holder() -> String {
        let text = (try? String(contentsOfFile: directory + "/holder", encoding: .utf8)) ?? ""
        return text.split(separator: "\n").first.map(String.init) ?? ""
    }

    /// Refuses to go on unless this run holds the lock: says why, then exits `busyStatus`.
    ///
    /// Call it as the **first** act of a UI test, before activating a window, sending a click or
    /// saving a picture, so a run without the lock touches nothing.
    public static func require(app: String) {
        let held = holder()
        let claimed = ProcessInfo.processInfo.environment["GLYPH_INPUT_LOCK_PID"]
        if heldByThisRun(holder: held, claimed: claimed) { return }
        print("UI REFUSED: \(app) does not hold this Mac's input lock, so it will not drive the screen.")
        print("  lock:     \(directory)")
        print("  holder:   \(held.isEmpty ? "(none)" : held)")
        print("  this run: \((claimed?.isEmpty == false) ? claimed! : "(GLYPH_INPUT_LOCK_PID is not set)")")
        print("  Take it first: source scripts/input-lock.sh, then take_input_lock <purpose>.")
        fflush(stdout)
        exit(busyStatus)
    }
}
