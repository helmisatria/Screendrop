import SwiftUI

struct FeaturesSettingsPane: View {
    @State private var features = FeatureSettings.shared

    var body: some View {
        Form {
            Section("Optional Features") {
                ForEach(ScreendropFeature.allCases) { feature in
                    Toggle(isOn: Binding(
                        get: { features.isEnabled(feature) },
                        set: { features.setEnabled($0, for: feature) }
                    )) {
                        SettingsControlLabel(feature.title, detail: feature.detail)
                    }
                    .toggleStyle(.switch)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.top, 8, for: .scrollContent)
    }
}
