import Foundation

// Compile with Screendrop/FeatureSettings.swift; uses an isolated preferences domain.
@main
struct FeatureSettingsChecks {
    @MainActor static func main() {
        let suite = "Screendrop.FeatureSettingsChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("keep", forKey: "unrelated")
        let settings = FeatureSettings(defaults: defaults)
        precondition(settings.isEnabled(.captions), "Existing users should retain captions by default")
        settings.setEnabled(false, for: .captions)
        precondition(!settings.isEnabled(.captions))
        let reopened = FeatureSettings(defaults: defaults)
        precondition(!reopened.isEnabled(.captions), "Opt-out must survive relaunch")
        reopened.setEnabled(true, for: .captions)
        precondition(FeatureSettings(defaults: defaults).isEnabled(.captions))
        precondition(defaults.string(forKey: "unrelated") == "keep")
        print("PASS: captions default, opt-out persistence, re-enable, unrelated preferences")
    }
}
