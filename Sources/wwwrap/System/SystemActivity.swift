import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac and the app responsive only while bytes are actually moving.
///
/// - IOKit `PreventUserIdleSystemSleep` assertion: the system won't idle-sleep mid-download,
///   but the display still sleeps (no `NoDisplaySleep`: that would cost far more battery).
///   Visible in Activity Monitor › Energy › "Preventing Sleep" and `pmset -g assertions`.
/// - `ProcessInfo` activity: opts out of App Nap so timers and URLSession callbacks
///   aren't throttled while the window is hidden.
/// Both are released the moment the last transfer stops.
@MainActor
final class SystemActivity {
    static let shared = SystemActivity()

    private var assertionID: IOPMAssertionID = IOPMAssertionID(0)
    private var holdsAssertion = false
    private var activity: NSObjectProtocol?

    private(set) var isPreventingSleep = false

    func update(transferring: Bool, preventSleep: Bool) {
        let wantAssertion = transferring && preventSleep
        if wantAssertion && !holdsAssertion {
            let result = IOPMAssertionCreateWithName(
                "PreventUserIdleSystemSleep" as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                L("wwwrap sedang mengunduh file") as CFString,
                &assertionID)
            holdsAssertion = result == kIOReturnSuccess
        } else if !wantAssertion && holdsAssertion {
            IOPMAssertionRelease(assertionID)
            holdsAssertion = false
        }
        isPreventingSleep = holdsAssertion

        if transferring && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Downloading files") // l10n-ignore
        } else if !transferring, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }
}
