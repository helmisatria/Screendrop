import Foundation
import Observation

nonisolated enum ScreendropFeature: String, CaseIterable, Identifiable, Sendable {
    case captions

    var id: Self { self }
    var preferenceKey: String { "feature.\(rawValue).enabled" }
    var defaultEnabled: Bool { true }
    var title: String {
        switch self { case .captions: "Captions" }
    }
    var detail: String {
        switch self {
        case .captions:
            "Show transcription and caption tools, and include captions in Studio previews and exports. Turning this off keeps your saved captions."
        }
    }
}

@MainActor
@Observable
final class FeatureSettings {
    static let shared = FeatureSettings()
    private let defaults: UserDefaults
    private var enabledFeatures: [ScreendropFeature: Bool]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabledFeatures = Dictionary(uniqueKeysWithValues: ScreendropFeature.allCases.map { feature in
            (feature, defaults.object(forKey: feature.preferenceKey) as? Bool ?? feature.defaultEnabled)
        })
    }

    func isEnabled(_ feature: ScreendropFeature) -> Bool {
        enabledFeatures[feature] ?? feature.defaultEnabled
    }

    func setEnabled(_ enabled: Bool, for feature: ScreendropFeature) {
        enabledFeatures[feature] = enabled
        defaults.set(enabled, forKey: feature.preferenceKey)
    }
}
