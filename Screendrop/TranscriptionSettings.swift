import Foundation
import Observation
import Security
import SwiftUI

nonisolated enum TranscriptionProvider: String, CaseIterable, Identifiable, Sendable {
    case onDevice
    case openRouter

    var id: Self { self }
    var title: String { self == .openRouter ? "OpenRouter" : "On this Mac" }
}

nonisolated struct CloudTranscriptionConfiguration: Sendable {
    let apiKey: String
    let model: String
    let pauseThreshold: Double
}

@MainActor
@Observable
final class TranscriptionSettings {
    static let shared = TranscriptionSettings()
    static let defaultModel = "microsoft/mai-transcribe-2"

    var provider: TranscriptionProvider {
        didSet { UserDefaults.standard.set(provider.rawValue, forKey: "transcriptionProvider") }
    }
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "transcriptionModel") }
    }
    var pauseThreshold: Double {
        didSet { UserDefaults.standard.set(pauseThreshold, forKey: "transcriptionPauseThreshold") }
    }
    private(set) var hasSavedKey = false

    private static var keyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.fayazahmed.Screendrop",
         kSecAttrAccount as String: "openrouter_transcription_api_key"]
    }

    private init() {
        let defaults = UserDefaults.standard
        provider = defaults.string(forKey: "transcriptionProvider")
            .flatMap(TranscriptionProvider.init(rawValue:)) ?? .openRouter
        model = defaults.string(forKey: "transcriptionModel") ?? Self.defaultModel
        pauseThreshold = defaults.object(forKey: "transcriptionPauseThreshold") as? Double ?? 0.6
        var query = Self.keyQuery
        query[kSecReturnPersistentRef as String] = true
        hasSavedKey = SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func saveKey(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ConfigurationError.message("Enter your OpenRouter API key first.") }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(Self.keyQuery as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(Self.keyQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ConfigurationError.keychain(status) }
        hasSavedKey = true
    }

    func removeKey() throws {
        let status = SecItemDelete(Self.keyQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ConfigurationError.keychain(status)
        }
        hasSavedKey = false
    }

    func snapshot() throws -> CloudTranscriptionConfiguration {
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedModel.isEmpty else { throw ConfigurationError.message("Enter an OpenRouter transcription model ID.") }
        var query = Self.keyQuery
        query[kSecReturnData as String] = true
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            throw ConfigurationError.message("Save your OpenRouter API key in Transcription settings first.")
        }
        guard status == errSecSuccess else { throw ConfigurationError.keychain(status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty else {
            throw ConfigurationError.message("Save your OpenRouter API key again.")
        }
        return CloudTranscriptionConfiguration(apiKey: key, model: selectedModel, pauseThreshold: pauseThreshold)
    }

    enum ConfigurationError: LocalizedError {
        case message(String)
        case keychain(OSStatus)

        var errorDescription: String? {
            switch self {
            case .message(let message): message
            case .keychain(let status): "Could not access the API key in Keychain (\(status))."
            }
        }
    }
}

struct TranscriptionSettingsControls: View {
    @State private var settings = TranscriptionSettings.shared
    @State private var keyDraft = ""
    @State private var keyMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: InspectorMetrics.rowSpacing) {
            Picker("Provider", selection: $settings.provider) {
                ForEach(TranscriptionProvider.allCases) { provider in
                    Text(provider.title).tag(provider)
                }
            }
            if settings.provider == .openRouter {
                TextField("Model ID", text: $settings.model, prompt: Text(TranscriptionSettings.defaultModel))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("OpenRouter model ID")
                SecureField(settings.hasSavedKey ? "Replace saved API key" : "OpenRouter API key", text: $keyDraft)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save Key") {
                        do {
                            try settings.saveKey(keyDraft)
                            keyDraft = ""
                            keyMessage = "API key saved in Keychain."
                        } catch { keyMessage = error.localizedDescription }
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if settings.hasSavedKey {
                        Button("Remove Key") {
                            do {
                                try settings.removeKey()
                                keyMessage = "API key removed."
                            } catch { keyMessage = error.localizedDescription }
                        }
                    }
                }
                if let keyMessage {
                    Text(keyMessage).font(.inspectorLabel).foregroundStyle(.secondary)
                } else if settings.hasSavedKey {
                    Label("API key saved", systemImage: "checkmark.circle").font(.inspectorLabel)
                }
                Text("Use a speech-to-text model that supports timestamps. Audio is sent to OpenRouter and its model provider when you click Transcribe. Charges use your OpenRouter account.")
                    .font(.inspectorLabel).foregroundStyle(.secondary)
                Link("Browse transcription models", destination: URL(string: "https://openrouter.ai/collections/speech-to-text")!)
                    .font(.inspectorLabel)
            } else {
                Text("On-device transcription requires macOS 26 or newer.")
                    .font(.inspectorLabel).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                Text("Split captions after \(settings.pauseThreshold, specifier: "%.1f") s of silence")
                    .font(.inspectorLabel)
                Slider(value: $settings.pauseThreshold, in: 0.3...1.5, step: 0.1)
                    .accessibilityLabel("Pause between captions")
            }
            Text("Applies to the next transcription. You can edit caption text afterward.")
                .font(.inspectorLabel).foregroundStyle(.secondary)
        }
        .font(.inspectorLabel)
        .controlSize(.small)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct TranscriptionSettingsPane: View {
    var body: some View {
        ScrollView {
            TranscriptionSettingsControls().padding(24)
        }
    }
}
