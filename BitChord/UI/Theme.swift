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

/// Cover art kept on the phone so it shows offline:
/// - downloaded songs: Documents/Artwork/<videoId>.jpg, kept as long as the download;
/// - songs you've played: Caches/RecentArtwork/<videoId>.jpg, the newest 400 kept
///   (iOS may clear Caches when storage runs low; they come back on the next play).
enum OfflineArtwork {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var downloaded: Set<String> = names(in: directory)
    nonisolated(unsafe) private static var recent: Set<String> = names(in: recentDirectory)
    private static let recentLimit = 400

    static var directory: URL { LibraryStore.documents.appendingPathComponent("Artwork", isDirectory: true) }
    static var recentDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RecentArtwork", isDirectory: true)
    }

    private static func key(_ videoId: String) -> String { videoId.replacingOccurrences(of: "/", with: "_") }
    private static func names(in dir: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return Set(files.filter { $0.hasSuffix(".jpg") }.map { String($0.dropLast(4)) })
    }

    static func url(for videoId: String) -> URL? {
        let k = key(videoId)
        lock.lock(); defer { lock.unlock() }
        if downloaded.contains(k) { return directory.appendingPathComponent(k + ".jpg") }
        if recent.contains(k) { return recentDirectory.appendingPathComponent(k + ".jpg") }
        return nil
    }

    /// Keeps a downloaded song's cover for as long as the download. False if it couldn't be fetched.
    @discardableResult
    static func save(_ song: Song) async -> Bool {
        if isDownloaded(song.videoId) { return true }
        // Reuse the copy kept from playing it, if there is one.
        let k = key(song.videoId)
        let kept = recentDirectory.appendingPathComponent(k + ".jpg")
        let data: Data?
        if FileManager.default.fileExists(atPath: kept.path) {
            data = try? Data(contentsOf: kept)
        } else {
            data = await fetch(song)
        }
        guard let data, write(data, to: directory, name: k) else { return false }
        lock.lock(); downloaded.insert(k); lock.unlock()
        return true
    }

    /// Keeps the cover of a song that's been played, for Recently Played and the player offline.
    static func remember(_ song: Song) async {
        guard !song.isLocal, url(for: song.videoId) == nil, let data = await fetch(song) else { return }
        let k = key(song.videoId)
        guard write(data, to: recentDirectory, name: k) else { return }
        lock.lock(); recent.insert(k); let count = recent.count; lock.unlock()
        if count > recentLimit + 50 { trimRecent() }
    }

    static func remove(_ videoId: String) {
        let k = key(videoId)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(k + ".jpg"))
        lock.lock(); downloaded.remove(k); lock.unlock()
    }

    static func removeAll() {
        try? FileManager.default.removeItem(at: directory)
        lock.lock(); downloaded.removeAll(); lock.unlock()
    }

    private static func isDownloaded(_ videoId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return downloaded.contains(key(videoId))
    }

    private static func fetch(_ song: Song) async -> Data? {
        guard let remote = song.artwork(720),
              let data = try? await ArtworkStore.session.data(from: remote).0,
              let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 0.85)
    }

    private static func write(_ data: Data, to dir: URL, name: String) -> Bool {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? data.write(to: dir.appendingPathComponent(name + ".jpg"), options: .atomic)) != nil
    }

    /// Drops the oldest kept covers of played songs.
    private static func trimRecent() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: recentDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 < $1.1 }).dropLast(recentLimit) {
            try? fm.removeItem(at: file)
            lock.lock(); recent.remove(file.deletingPathExtension().lastPathComponent); lock.unlock()
        }
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
