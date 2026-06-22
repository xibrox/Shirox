import Foundation

/// Tap-to-open routing for an on-device-only library entry. Carried on `LibraryEntry`
/// because a `Media` cannot hold a module href or an imported filename.
struct LocalSource: Codable, Hashable, Sendable {
    enum Kind: String, Codable { case module, localFile }
    var kind: Kind
    var moduleId: String?        // module: which module produced it
    var detailHref: String?      // module: how to reopen its detail screen
    var localImportName: String? // localFile: imported filename to resume
}
