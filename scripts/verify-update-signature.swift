import CryptoKit
import Foundation

// Verify against the public key embedded in the actual app, not the signing keychain.
do {
    let arguments = CommandLine.arguments
    guard arguments.count == 4 else {
        throw NSError(domain: "Usage: verify-update-signature.swift ARCHIVE APP_INFO_PLIST APPCAST", code: 1)
    }
    let archive = URL(fileURLWithPath: arguments[1])
    let infoData = try Data(contentsOf: URL(fileURLWithPath: arguments[2]))
    guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
          let publicKeyString = info["SUPublicEDKey"] as? String,
          let publicKeyData = Data(base64Encoded: publicKeyString),
          let version = info["CFBundleShortVersionString"] as? String,
          let build = info["CFBundleVersion"] as? String else {
        throw NSError(domain: "Missing release identity or public key", code: 1)
    }
    let feed = try XMLDocument(contentsOf: URL(fileURLWithPath: arguments[3]))
    let items = try feed.nodes(forXPath: "/rss/channel/item")
    guard items.count == 1, let item = items.first,
          let enclosure = try item.nodes(forXPath: "enclosure").first as? XMLElement,
          let signatureString = enclosure.attribute(forLocalName: "edSignature", uri: "http://www.andymatuschak.org/xml-namespaces/sparkle")?.stringValue,
          let signature = Data(base64Encoded: signatureString) else {
        throw NSError(domain: "Expected one signed update in appcast", code: 1)
    }
    let archiveData = try Data(contentsOf: archive, options: .mappedIfSafe)
    let expectedURL = "https://github.com/helmisatria/Screendrop/releases/download/v\(version)/\(archive.lastPathComponent)"
    let versions = try item.nodes(forXPath: "*[local-name()='version']")
    guard enclosure.attribute(forName: "url")?.stringValue == expectedURL,
          enclosure.attribute(forName: "length")?.stringValue == String(archiveData.count),
          versions.first?.stringValue == build else {
        throw NSError(domain: "Appcast URL, size or build does not match the release", code: 1)
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    guard key.isValidSignature(signature, for: archiveData) else {
        throw NSError(domain: "Update signature does not match the app's embedded public key", code: 1)
    }
    print("Verified appcast and archive signature against the app's embedded public key.")
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
