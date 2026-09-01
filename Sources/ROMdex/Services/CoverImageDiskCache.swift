import AppKit
import CryptoKit
import Foundation

/// Cache disque des jaquettes (JPEG recompressé) — hors export catalogue.
@MainActor
final class CoverImageDiskCache: ObservableObject {
    static let shared = CoverImageDiskCache()

    /// Qualité max réseau pour l’affichage (session uniquement, non persistée).
    @Published var preferMaximumQuality = false

    /// Taille affichée dans le menu Paramètres.
    @Published private(set) var formattedByteSize: String = "0 o"

    private let maxEdge: CGFloat = 512
    private let jpegQuality: CGFloat = 0.78
    private let folderName = "Covers"
    private let appSupportName = "ROMdex"

    /// Dossier disque des JPEG (export / import catalogue).
    var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent(appSupportName, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    /// `true` s’il existe au moins un fichier jaquette.
    var hasCachedCovers: Bool {
        byteSize() > 0
    }

    private var sizeRefreshTask: Task<Void, Never>?

    private init() {
        refreshSize()
    }

    // MARK: - Public

    func fileURL(forRemoteURL url: URL) -> URL {
        let hash = SHA256.hash(data: Data(url.absoluteString.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent("\(hex).jpg", isDirectory: false)
    }

    func loadImage(forRemoteURL url: URL) -> NSImage? {
        let path = fileURL(forRemoteURL: url)
        guard FileManager.default.fileExists(atPath: path.path),
              let data = try? Data(contentsOf: path),
              let image = NSImage(data: data),
              image.size.width > 0 else {
            return nil
        }
        return image
    }

    /// Enregistre une version JPEG allégée (jamais la qualité réseau brute).
    func store(image: NSImage, forRemoteURL url: URL) {
        guard let data = jpegData(from: image) else { return }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let dest = fileURL(forRemoteURL: url)
            let tmp = dest.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
            scheduleSizeRefresh()
        } catch {
            // Échec disque non bloquant.
        }
    }

    func clear() {
        sizeRefreshTask?.cancel()
        try? FileManager.default.removeItem(at: directoryURL)
        refreshSize()
    }

    /// Copie le dossier Covers vers `destination/Covers` (export ZIP).
    func copyCachedCovers(toParent destinationParent: URL) throws -> Int {
        let fm = FileManager.default
        let source = directoryURL
        guard fm.fileExists(atPath: source.path) else { return 0 }

        let dest = destinationParent.appendingPathComponent(folderName, isDirectory: true)
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)

        var count = 0
        let files = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension.lowercased() == "jpg" {
            try fm.copyItem(at: file, to: dest.appendingPathComponent(file.lastPathComponent))
            count += 1
        }
        return count
    }

    /// Importe des jaquettes depuis un dossier `Covers` extrait d’une archive.
    func importCovers(from sourceDirectory: URL, replaceExisting: Bool) throws -> Int {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sourceDirectory.path) else { return 0 }

        if replaceExisting {
            try? fm.removeItem(at: directoryURL)
        }
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var count = 0
        let files = try fm.contentsOfDirectory(at: sourceDirectory, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension.lowercased() == "jpg" {
            let dest = directoryURL.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: file, to: dest)
            count += 1
        }
        refreshSize()
        return count
    }

    func refreshSize() {
        formattedByteSize = Self.formatBytes(byteSize())
    }

    private func scheduleSizeRefresh() {
        sizeRefreshTask?.cancel()
        sizeRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            refreshSize()
        }
    }

    func byteSize() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize else {
                continue
            }
            total += Int64(size)
        }
        return total
    }

    static func formatBytes(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) o" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.0f Ko", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.0f Mo", mb.rounded()) }
        let gb = mb / 1024
        return String(format: "%.1f Go", gb)
    }

    // MARK: - JPEG

    private func jpegData(from image: NSImage) -> Data? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        let srcW = CGFloat(cgImage.width)
        let srcH = CGFloat(cgImage.height)
        guard srcW > 0, srcH > 0 else { return nil }

        let scale = min(1, maxEdge / max(srcW, srcH))
        let outW = max(1, Int((srcW * scale).rounded()))
        let outH = max(1, Int((srcH * scale).rounded()))

        let rep: NSBitmapImageRep
        if scale < 1 {
            guard let scaled = resizedCGImage(cgImage, width: outW, height: outH) else { return nil }
            rep = NSBitmapImageRep(cgImage: scaled)
        } else {
            rep = NSBitmapImageRep(cgImage: cgImage)
        }

        return rep.representation(
            using: .jpeg,
            properties: [.compressionFactor: jpegQuality]
        )
    }

    private func resizedCGImage(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            // Fallback avec alpha si le format source le nécessite.
            guard let fallback = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return nil
            }
            fallback.interpolationQuality = .high
            fallback.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return fallback.makeImage()
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
