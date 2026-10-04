import AppKit
import CoreText
import CryptoKit
import Foundation
import Observation

nonisolated struct RecordingGoogleFont: Codable, Hashable, Sendable {
    let family: String
    let variant: String
    let fileURL: URL
    let postScriptName: String
}

nonisolated struct RecordingFontFamily: Codable, Identifiable, Sendable {
    var id: String { family }
    let family: String
    let category: String
    let version: String
    let variants: [String]
    let files: [String: URL]

    static func variantTitle(_ variant: String) -> String {
        let italic = variant.contains("italic")
        let weight = variant.replacingOccurrences(of: "italic", with: "")
        let names = ["": "Regular", "regular": "Regular", "100": "Thin", "200": "Extra Light",
                     "300": "Light", "400": "Regular", "500": "Medium", "600": "Semibold",
                     "700": "Bold", "800": "Extra Bold", "900": "Black"]
        return (names[weight] ?? weight) + (italic ? " Italic" : "")
    }
}

@MainActor @Observable
final class RecordingGoogleFonts {
    static let shared = RecordingGoogleFonts()
    static let catalogURL = URL(string: "https://screendrop-fonts.helmisatria.workers.dev/v1/fonts")!

    private(set) var families: [RecordingFontFamily] = []
    private(set) var isLoadingCatalog = false
    private(set) var catalogError: String?
    private(set) var registeredFonts: [URL: String] = [:]
    private var downloads: [URL: Task<String, Error>] = [:]
    private var lastCatalogLoad: Date?

    private struct Catalog: Codable { let items: [RecordingFontFamily] }

    enum FontError: LocalizedError {
        case unavailable, invalidFont, invalidURL
        var errorDescription: String? {
            switch self {
            case .unavailable: "The font could not be downloaded. Check your connection and retry."
            case .invalidFont: "The downloaded font could not be opened. Choose another font or retry."
            case .invalidURL: "This font has an unsupported download address."
            }
        }
    }

    private var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.fayazahmed.Screendrop")
            .appendingPathComponent("GoogleFonts", isDirectory: true)
    }

    func loadCatalog(force: Bool = false) async {
        guard !isLoadingCatalog else { return }
        if !force, let lastCatalogLoad, Date().timeIntervalSince(lastCatalogLoad) < 86400 { return }
        isLoadingCatalog = true
        catalogError = nil
        defer { isLoadingCatalog = false }
        let cachedURL = storageURL.appendingPathComponent("catalog.json")
        if families.isEmpty, let data = try? Data(contentsOf: cachedURL),
           let cached = try? JSONDecoder().decode(Catalog.self, from: data) {
            families = cached.items
        }
        do {
            var request = URLRequest(url: Self.catalogURL)
            request.setValue("Screendrop/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FontError.unavailable }
            let catalog = try JSONDecoder().decode(Catalog.self, from: data)
            guard !catalog.items.isEmpty else { throw FontError.unavailable }
            families = catalog.items
            lastCatalogLoad = Date()
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            try data.write(to: cachedURL, options: .atomic)
        } catch {
            catalogError = families.isEmpty
                ? "Could not load Google Fonts. Check your connection and retry."
                : "Showing the saved font list. Could not refresh it."
        }
    }

    func select(_ family: RecordingFontFamily, variant: String) async throws -> RecordingGoogleFont {
        guard let url = family.files[variant] else { throw FontError.unavailable }
        let name = try await loadFont(at: url)
        return RecordingGoogleFont(family: family.family, variant: variant, fileURL: url, postScriptName: name)
    }

    func prepare(_ font: RecordingGoogleFont?) async throws {
        guard let font else { return }
        let name = try await loadFont(at: font.fileURL)
        guard name == font.postScriptName else { throw FontError.invalidFont }
    }

    func isReady(_ font: RecordingGoogleFont?) -> Bool {
        guard let font else { return true }
        return registeredFonts[font.fileURL] == font.postScriptName
    }

    private func loadFont(at url: URL) async throws -> String {
        guard url.scheme == "https", url.host == "fonts.gstatic.com", url.pathExtension == "ttf",
              url.user == nil, url.password == nil, url.query == nil else { throw FontError.invalidURL }
        if let name = registeredFonts[url] { return name }
        if let pending = downloads[url] { return try await pending.value }
        let directory = storageURL
        let task = Task<String, Error> {
            let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
            let file = directory.appendingPathComponent(digest + ".ttf")
            if FileManager.default.fileExists(atPath: file.path) {
                if let name = try? Self.register(file) { return name }
                try? FileManager.default.removeItem(at: file)
            }
            var request = URLRequest(url: url)
            request.setValue("Screendrop/1.0", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 60
            let (temporary, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  http.url?.scheme == "https", http.url?.host == "fonts.gstatic.com" else {
                throw FontError.unavailable
            }
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 50_000_000 else { throw FontError.invalidFont }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: file)
            do { return try Self.register(file) }
            catch { try? FileManager.default.removeItem(at: file); throw error }
        }
        downloads[url] = task
        defer { downloads[url] = nil }
        let name = try await task.value
        registeredFonts[url] = name
        return name
    }

    private static func register(_ url: URL) throws -> String {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else {
            throw FontError.invalidFont
        }
        var error: Unmanaged<CFError>?
        let registered = CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        if !registered {
            let code = error.map { CFErrorGetCode($0.takeRetainedValue()) }
            guard code == CTFontManagerError.alreadyRegistered.rawValue else { throw FontError.invalidFont }
        }
        guard NSFont(name: name, size: 16) != nil else { throw FontError.invalidFont }
        return name
    }
}
