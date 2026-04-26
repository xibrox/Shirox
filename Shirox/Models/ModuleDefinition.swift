import Foundation

struct ModuleDefinition: Codable, Identifiable, Equatable {
    var id: String { scriptUrl }
    let sourceName: String
    let iconUrl: String?
    let author: ModuleAuthor?
    let version: String
    let baseUrl: String
    let searchBaseUrl: String?
    let scriptUrl: String
    let type: String
    let asyncJS: Bool?
    let streamType: String?
    let quality: String?
    let language: String?
    let softsub: Bool?
    var jsonUrl: String?     // stored client-side; not present in module JSON
    var scriptContent: String? // cached script content
    var iconData: String?      // cached icon data (Base64)
}

struct ModuleAuthor: Codable, Equatable {
    let name: String
    let icon: String?
}
