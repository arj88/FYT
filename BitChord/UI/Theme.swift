import SwiftUI
import UIKit

enum Theme {
    /// The accent colour the user picked in Settings.
    @MainActor static var accent: Color {
        let settings = AppSettings.shared
        if settings.accent == .custom { return Color(hex: settings.customAccentHex) ?? AccentChoice.red.color }
        return settings.accent.color
    }
    static let secondaryText = Color(UIColor.secondaryLabel)
    static let cardCorner: CGFloat = 8
}

extension Song {
    /// Artwork for any song, including imported files.
    func artworkURL(_ size: Int) -> URL? {
        if isLocal { return LocalMetadata.artworkURL(for: self) }
        // Downloaded songs use their saved cover, so it shows offline too.
        if let saved = OfflineArtwork.url(for: videoId) { return saved }
        return artwork(size)
    }
}

/// Cover art saved alongside downloaded songs (Documents/Artwork/<videoId>.jpg).
enum OfflineArtwork {
    nonisolated(unsafe) private static var known: Set<String> = loadKnown()
    private static let lock = NSLock()

    static var directory: URL { LibraryStore.documents.appendingPathComponent("Artwork", isDirectory: true) }

    private static func file(_ videoId: String) -> URL {
        directory.appendingPathComponent(videoId.replacingOccurrences(of: "/", with: "_") + ".jpg")
    }

    private static func loadKnown() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return Set(names.filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) })
    }

    static func url(for videoId: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return known.contains(videoId.replacingOccurrences(of: "/", with: "_")) ? file(videoId) : nil
    }

    /// Downloads and keeps a song's cover. Returns false if it couldn't be fetched (e.g. offline).
    @discardableResult
    static func save(_ song: Song) async -> Bool {
        if url(for: song.videoId) != nil { return true }
        guard let remote = song.artwork(720),
              let data = try? await ArtworkStore.session.data(from: remote).0,
              let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.85) else { return false }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard (try? jpeg.write(to: file(song.videoId), options: .atomic)) != nil else { return false }
        lock.lock(); known.insert(song.videoId.replacingOccurrences(of: "/", with: "_")); lock.unlock()
        return true
    }

    static func remove(_ videoId: String) {
        try? FileManager.default.removeItem(at: file(videoId))
        lock.lock(); known.remove(videoId.replacingOccurrences(of: "/", with: "_")); lock.unlock()
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        lock.lock(); known.removeAll(); lock.unlock()
    }
}

/// In-memory + URLCache-backed image loading shared by every artwork view.
enum ArtworkStore {
    private static let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 400
        c.totalCostLimit = 120 * 1024 * 1024   // decoded bitmaps, so cap by memory too
        return c
    }()

    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 300 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    static func cached(_ url: URL?) -> UIImage? {
        guard let url else { return nil }
        return cache.object(forKey: url as NSURL)
    }

    static func image(for url: URL?) async -> UIImage? {
        guard let url else { return nil }
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = try? await session.data(from: url).0
        }
        guard let data, let image = UIImage(data: data) else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) { image.preparingForDisplay() ?? image }.value
        let cost = Int(decoded.size.width * decoded.scale * decoded.size.height * decoded.scale * 4)
        cache.setObject(decoded, forKey: url as NSURL, cost: cost)
        return decoded
    }

    static func prefetch(_ url: URL?) {
        Task.detached(priority: .background) { _ = await ArtworkStore.image(for: url) }
    }
}

struct ArtworkImage: View {
    let url: URL?
    var cornerRadius: CGFloat = Theme.cardCorner
    var circle = false
    var placeholderIcon = "music.note"

    @State private var image: UIImage?

    var body: some View {
        // The rectangle takes exactly the space offered; the image only fills it as an
        // overlay, so a scaled-to-fill picture can never widen the layout around it.
        Rectangle()
            .fill(Color(UIColor.secondarySystemFill))
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    Image(systemName: placeholderIcon)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .clipped()
        .clipShape(circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)))
        .overlay {
            if !circle {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            }
        }
        .task(id: url) {
            if let hit = ArtworkStore.cached(url) { image = hit; return }
            image = nil
            let loaded = await ArtworkStore.image(for: url)
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}

/// Dominant colours of an artwork, for the player background.
enum ArtworkPalette {
    static func colors(from image: UIImage, count: Int = 4) -> [Color] {
        let side = 12
        guard let cg = image.cgImage else { return [] }
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        // Average each quadrant, then boost saturation a little so the backdrop isn't muddy.
        var result: [Color] = []
        let half = side / 2
        let quads = [(0, 0), (half, 0), (0, half), (half, half)]
        for (qx, qy) in quads.prefix(count) {
            var r = 0.0, g = 0.0, b = 0.0, n = 0.0
            for y in qy..<(qy + half) {
                for x in qx..<(qx + half) {
                    let i = (y * side + x) * 4
                    r += Double(pixels[i]); g += Double(pixels[i + 1]); b += Double(pixels[i + 2]); n += 1
                }
            }
            let ui = UIColor(red: r / n / 255, green: g / n / 255, blue: b / n / 255, alpha: 1)
            var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
            ui.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
            let adjusted = UIColor(hue: h, saturation: min(1, s * 1.25), brightness: min(0.78, max(0.22, v * 0.9)), alpha: 1)
            result.append(Color(adjusted))
        }
        return result
    }
}

struct ExplicitBadge: View {
    var body: some View {
        Text("E")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Color(UIColor.systemBackground))
            .frame(width: 13, height: 13)
            .background(RoundedRectangle(cornerRadius: 2).fill(Color.secondary))
    }
}

extension View {
    @ViewBuilder
    func `if`<T: View>(_ condition: Bool, transform: (Self) -> T) -> some View {
        if condition { transform(self) } else { self }
    }
}
