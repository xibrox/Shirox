import Combine
import CoreGraphics
import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformIconImage = UIImage
#else
import AppKit
typealias PlatformIconImage = NSImage
#endif

// MARK: - Pack

/// An icon pack: a pack.json and one vector PDF per icon, published at `url`. The format and
/// how packs are made are described in scripts/icons/icons.py.
struct IconPack: Codable, Equatable {
    var name: String
    var author: String?
    var license: String?
    var website: String?
    /// Where the pack's own pack.json is published; icon paths are relative to it.
    var url: String
    /// The icons.json version the pack was made for (see `IconManifest`).
    var iconsVersion: Int
    var packVersion: Int
    var icons: [String: String]
    /// The icons keep their own colours instead of taking the tint, for packs drawn in colour
    /// (`"multicolor": true` in pack.json). Absent in most packs: those are tinted shapes.
    var multicolor: Bool?

    /// Made for the icons this build uses: anything else isn't loaded at all.
    var fitsThisBuild: Bool { iconsVersion == IconManifest.version }
}

/// A pack on this device: its pack.json and the folder its icons were downloaded to.
struct InstalledIconPack: Identifiable, Equatable {
    let pack: IconPack
    let folder: URL
    var id: String { pack.url }
}

enum IconPackError: LocalizedError {
    case notHTTPS
    case unreadable
    case wrongVersion(Int)
    case download(String)

    var errorDescription: String? {
        switch self {
        case .notHTTPS:
            return String(localized: "settings.icon_pack_needs_https")
        case .unreadable:
            return String(localized: "settings.icon_pack_unreadable")
        case .wrongVersion(let version):
            return String(localized: "settings.icon_pack_wrong_version \(version) \(IconManifest.version)")
        case .download(let icon):
            return String(localized: "settings.icon_pack_download_failed \(icon)")
        }
    }
}

// MARK: - Store

/// The packs downloaded to this device, the one in use, and their updates. Packs live in
/// Application Support/IconPacks, one folder each; the choice is kept by the pack's url.
@MainActor
final class IconPackStore: ObservableObject {
    static let shared = IconPackStore()
    static let selectedKey = "iconPackURL"

    @Published private(set) var installed: [InstalledIconPack] = []
    /// Packs with a newer version at their url, by url.
    @Published private(set) var updates: [String: IconPack] = [:]
    /// The pack in use, by url; empty for SF Symbols.
    @Published private(set) var selectedURL: String
    /// Goes up whenever the icons drawn change: the app rebuilds its views on it, since an
    /// icon is looked up when its view is made.
    @Published private(set) var revision = 0

    /// The official packs are listed on the website, each with the link to add it here.
    static let websiteAddress = "shiroxapp.github.io/iconpacks"
    static var websiteURL: URL? { URL(string: "https://\(websiteAddress)/") }

    /// Where the packs were published before they moved to the website, with the same
    /// folders under it. Nightly and TestFlight builds installed packs from there.
    private static let legacyPrefix = "https://raw.githubusercontent.com/xibrox/Shirox/main/iconpacks/"

    /// A pack url from the old address, moved to the same pack on the website; any other url
    /// as it is. Applied to installed packs, the saved choice and links pasted in, so packs
    /// from before the move keep updating instead of checking a folder that is gone.
    static func migrated(_ url: String) -> String {
        guard url.hasPrefix(legacyPrefix) else { return url }
        return "https://\(websiteAddress)/" + url.dropFirst(legacyPrefix.count)
    }

    private let root: URL

    private init() {
        root = AppDirectories.applicationSupport.appendingPathComponent("IconPacks", isDirectory: true)
        let stored = UserDefaults.standard.string(forKey: Self.selectedKey) ?? ""
        selectedURL = Self.migrated(stored)
        if selectedURL != stored { UserDefaults.standard.set(selectedURL, forKey: Self.selectedKey) }
        reload()
    }

    var selected: InstalledIconPack? { installed.first { $0.pack.url == selectedURL } }

    func select(_ pack: InstalledIconPack?) {
        selectedURL = pack?.pack.url ?? ""
        UserDefaults.standard.set(selectedURL, forKey: Self.selectedKey)
        applySelection()
    }

    /// Downloads the pack published at `link`, or the newer version of one already here.
    func install(from link: String) async throws {
        guard let url = URL(string: Self.migrated(link.trimmingCharacters(in: .whitespacesAndNewlines))),
              url.scheme == "https" else { throw IconPackError.notHTTPS }
        let pack = try await Self.fetchPack(at: url)
        guard pack.fitsThisBuild else { throw IconPackError.wrongVersion(pack.iconsVersion) }
        // Into a fresh folder, then swapped in: a failed download leaves the old copy working.
        let staging = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            try await Self.downloadIcons(of: pack, from: url, into: staging)
            try JSONEncoder().encode(pack).write(to: staging.appendingPathComponent("pack.json"))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        if let old = installed.first(where: { $0.pack.url == pack.url }) {
            try? FileManager.default.removeItem(at: old.folder)
        }
        updates[pack.url] = nil
        reload()
        if pack.url == selectedURL { applySelection() }
    }

    func remove(_ pack: InstalledIconPack) {
        try? FileManager.default.removeItem(at: pack.folder)
        updates[pack.pack.url] = nil
        if pack.pack.url == selectedURL { select(nil) }
        reload()
    }

    /// Looks for a newer version of every pack here, at the url each was published at.
    func checkForUpdates() async {
        for item in installed {
            guard let url = URL(string: item.pack.url),
                  let latest = try? await Self.fetchPack(at: url) else { continue }
            let newer = latest.packVersion > item.pack.packVersion
                || (!item.pack.fitsThisBuild && latest.fitsThisBuild)
            updates[item.pack.url] = newer && latest.fitsThisBuild ? latest : nil
        }
    }

    func update(_ pack: InstalledIconPack) async throws {
        try await install(from: pack.pack.url)
    }

    // MARK: Loading

    private func reload() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        installed = folders.compactMap { folder in
            let file = folder.appendingPathComponent("pack.json")
            guard let data = try? Data(contentsOf: file),
                  var pack = try? JSONDecoder().decode(IconPack.self, from: data) else { return nil }
            // Installed from the old address: point it at the website, on disk too. The icons
            // are local files and stay as they are.
            let url = Self.migrated(pack.url)
            if url != pack.url {
                pack.url = url
                try? JSONEncoder().encode(pack).write(to: file)
            }
            return InstalledIconPack(pack: pack, folder: folder)
        }
        .sorted { $0.pack.name.localizedCaseInsensitiveCompare($1.pack.name) == .orderedAscending }
        applySelection()
    }

    /// Hands the pack in use to the renderer; one made for other icons isn't used at all.
    private func applySelection() {
        let before = IconPackRenderer.shared.activeURL
        if let selected, selected.pack.fitsThisBuild {
            IconPackRenderer.shared.use(selected)
        } else {
            IconPackRenderer.shared.use(nil)
        }
        if IconPackRenderer.shared.activeURL != before || selected != nil { revision += 1 }
    }

    private static func fetchPack(at url: URL) async throws -> IconPack {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let pack = try? JSONDecoder().decode(IconPack.self, from: data) else {
            throw IconPackError.unreadable
        }
        return pack
    }

    private static func downloadIcons(of pack: IconPack, from url: URL, into folder: URL) async throws {
        try await withThrowingTaskGroup(of: (String, Data).self) { group in
            var pending = pack.icons.makeIterator()
            func next() {
                guard let (name, path) = pending.next() else { return }
                group.addTask {
                    // Inside the pack's folder only: no "../" out of it, no other hosts.
                    guard !path.contains(".."), let file = URL(string: path, relativeTo: url),
                          file.host == url.host, file.scheme == "https" else {
                        throw IconPackError.download(name)
                    }
                    let (data, response) = try await URLSession.shared.data(from: file)
                    guard (response as? HTTPURLResponse)?.statusCode == 200,
                          data.starts(with: Array("%PDF".utf8)) else { throw IconPackError.download(name) }
                    return (path, data)
                }
            }
            // A few at a time, not hundreds of requests at once.
            for _ in 0..<8 { next() }
            while let (path, data) = try await group.next() {
                let target = folder.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try data.write(to: target)
                next()
            }
        }
    }
}

// MARK: - Rendering

/// Draws the pack in use's icons, from any thread: views ask for icons while they're built.
final class IconPackRenderer: @unchecked Sendable {
    static let shared = IconPackRenderer()

    private let lock = NSLock()
    private var pack: InstalledIconPack?
    private var documents: [String: CGPDFDocument] = [:]
    private var images: [String: PlatformIconImage] = [:]

    /// Whether a pack is in use, for the views to tell when to rebuild.
    var activeURL: String? {
        lock.lock(); defer { lock.unlock() }
        return pack?.pack.url
    }

    func use(_ pack: InstalledIconPack?) {
        lock.lock(); defer { lock.unlock() }
        guard pack != self.pack else { return }
        self.pack = pack
        documents = [:]
        images = [:]
    }

    /// The pack's icon for an SF Symbol name at a size in points: a template image to tint, or
    /// for a multicolor pack one drawn in its own colours; nil without a pack, or when the pack
    /// has no such icon.
    func image(_ name: String, pointSize: CGFloat) -> PlatformIconImage? {
        lock.lock(); defer { lock.unlock() }
        guard let pack, let path = pack.pack.icons[name] else { return nil }
        let key = "\(name)@\(pointSize)"
        if let image = images[key] { return image }
        let document: CGPDFDocument
        if let cached = documents[name] {
            document = cached
        } else {
            guard let loaded = CGPDFDocument(pack.folder.appendingPathComponent(path) as CFURL) else { return nil }
            documents[name] = loaded
            document = loaded
        }
        guard let page = document.page(at: 1) else { return nil }
        let image = Self.render(page, pointSize: pointSize, template: pack.pack.multicolor != true)
        images[key] = image
        return image
    }

    /// The page fitted into a square of `pointSize`, kept in proportion; a template image unless
    /// the pack keeps its colours.
    private static func render(_ page: CGPDFPage, pointSize: CGFloat, template: Bool) -> PlatformIconImage {
        let box = page.getBoxRect(.mediaBox)
        let fit = min(pointSize / max(box.width, 1), pointSize / max(box.height, 1))
        let size = CGSize(width: box.width * fit, height: box.height * fit)
        let draw = { (context: CGContext) in
            context.scaleBy(x: fit, y: fit)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
        }
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            // UIKit's context is flipped against the PDF's.
            renderer.cgContext.translateBy(x: 0, y: size.height)
            renderer.cgContext.scaleBy(x: 1, y: -1)
            draw(renderer.cgContext)
        }
        return image.withRenderingMode(template ? .alwaysTemplate : .alwaysOriginal)
        #else
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(context)
            return true
        }
        image.isTemplate = template
        return image
        #endif
    }
}

// MARK: - Views

extension Image {
    /// A pack's icon as SwiftUI draws it: tinted like a symbol, or in its own colours when the
    /// renderer made it that way for a multicolor pack.
    init(packIcon image: PlatformIconImage) {
        #if canImport(UIKit)
        self = Image(uiImage: image).renderingMode(image.renderingMode == .alwaysOriginal ? .original : .template)
        #else
        self = Image(nsImage: image).renderingMode(image.isTemplate ? .template : .original)
        #endif
    }

    /// An icon by its SF Symbol name: the pack's when one is in use, the symbol otherwise.
    /// For places that need an `Image`: tab bars, menus, labels. A pack's icon is drawn at
    /// `pointSize` there, since an image from a file doesn't follow the font as a symbol does.
    init(icon name: String, pointSize: CGFloat = 20) {
        if let image = IconPackRenderer.shared.image(name, pointSize: pointSize) {
            self = Image(packIcon: image)
        } else {
            self.init(systemName: name)
        }
    }
}

/// An icon by its SF Symbol name, sized by the font like the symbol it stands in for: the
/// pack's icon fills the space the symbol would take.
struct IconView: View {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        if let image = IconPackRenderer.shared.image(name, pointSize: 64) {
            Image(systemName: name)
                .hidden()
                .overlay {
                    Image(packIcon: image).resizable().scaledToFit()
                }
                .accessibilityElement(children: .ignore)
        } else {
            Image(systemName: name)
        }
    }
}

extension Label where Title == Text, Icon == Image {
    /// A label whose icon comes from the icon pack in use.
    init(_ titleKey: LocalizedStringKey, icon name: String) {
        self.init { Text(titleKey) } icon: { Image(icon: name) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, icon name: String) {
        self.init { Text(title) } icon: { Image(icon: name) }
    }
}
