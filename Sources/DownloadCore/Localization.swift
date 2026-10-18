import Foundation

/// Lets the app translate the engine's user-facing messages (error descriptions).
///
/// The engine writes Indonesian source text; the app installs `lookup` at launch to map it
/// to the current language. Without the app (tests, mdl-bench) messages stay Indonesian.
public enum EngineLocalization {
    private static let lock = NSLock()
    private static var _lookup: @Sendable (String) -> String = { $0 }

    public static var lookup: @Sendable (String) -> String {
        get { lock.lock(); defer { lock.unlock() }; return _lookup }
        set { lock.lock(); _lookup = newValue; lock.unlock() }
    }
}

/// Engine-side translation: same contract as the app's `L` (Indonesian key, `%ld`/`%@` arguments).
func L(_ key: String, _ args: CVarArg...) -> String {
    let template = EngineLocalization.lookup(key)
    return args.isEmpty ? template : String(format: template, arguments: args)
}
