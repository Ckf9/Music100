import Foundation
import SwiftUI
import UIKit

struct Track: Identifiable, Equatable, Codable {
    let id: Int
    let title: String
    let artist: String
    let isDownloaded: Bool
    var coverBase64: String?
    var coverURL: String?
    let sourceFileName: String
    var cachedCoverImage: UIImage?
    
    var previewUrl: String? = nil
    
    var isPreloaded: Bool = false
    var isPreloading: Bool = false
    var preloadedProxyUrl: URL? = nil
    var preloadedLyrics: [LyricLine]? = nil
    
    enum CodingKeys: String, CodingKey {
        case id, title, artist, isDownloaded, coverBase64, coverURL, sourceFileName, previewUrl, isPreloaded, preloadedProxyUrl, preloadedLyrics
    }
    
    init(id: Int, title: String, artist: String, isDownloaded: Bool, coverBase64: String? = nil, coverURL: String? = nil, sourceFileName: String, previewUrl: String? = nil, cachedCoverImage: UIImage? = nil) {
        self.id = id
        
        let cleanedTitle = title
            .replacingOccurrences(of: ".enhance", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "enhance", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            
        self.title = cleanedTitle
        self.artist = artist
        self.isDownloaded = isDownloaded
        self.coverBase64 = coverBase64
        self.coverURL = coverURL
        self.sourceFileName = sourceFileName
        self.previewUrl = previewUrl
        self.cachedCoverImage = cachedCoverImage
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        isDownloaded = try container.decode(Bool.self, forKey: .isDownloaded)
        coverBase64 = try container.decodeIfPresent(String.self, forKey: .coverBase64)
        coverURL = try container.decodeIfPresent(String.self, forKey: .coverURL)
        sourceFileName = try container.decode(String.self, forKey: .sourceFileName)
        previewUrl = try container.decodeIfPresent(String.self, forKey: .previewUrl)
        isPreloaded = try container.decodeIfPresent(Bool.self, forKey: .isPreloaded) ?? false
        preloadedProxyUrl = try container.decodeIfPresent(URL.self, forKey: .preloadedProxyUrl)
        preloadedLyrics = try container.decodeIfPresent([LyricLine].self, forKey: .preloadedLyrics)
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(isDownloaded, forKey: .isDownloaded)
        try container.encodeIfPresent(coverBase64, forKey: .coverBase64)
        try container.encodeIfPresent(coverURL, forKey: .coverURL)
        try container.encode(sourceFileName, forKey: .sourceFileName)
        try container.encodeIfPresent(previewUrl, forKey: .previewUrl)
        try container.encode(isPreloaded, forKey: .isPreloaded)
        try container.encodeIfPresent(preloadedProxyUrl, forKey: .preloadedProxyUrl)
        try container.encodeIfPresent(preloadedLyrics, forKey: .preloadedLyrics)
    }
    
    static func == (lhs: Track, rhs: Track) -> Bool {
        return lhs.id == rhs.id
    }
    
    static let imageCache = NSCache<NSString, UIImage>()
    
    func getUIImage() -> UIImage? {
        if let uiImage = cachedCoverImage {
            return uiImage
        }
        
        let cacheKey = NSString(string: "\(id)")
        if let cached = Track.imageCache.object(forKey: cacheKey) {
            return cached
        }
        
        // Check for custom cover in Documents
        if let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let customCoverURL = docsURL.appendingPathComponent("\(sourceFileName).cover.jpg")
            if FileManager.default.fileExists(atPath: customCoverURL.path),
               let uiImage = UIImage(contentsOfFile: customCoverURL.path) {
                Track.imageCache.setObject(uiImage, forKey: cacheKey)
                return uiImage
            }
        }
        
        if let base64 = coverBase64,
           let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
           let uiImage = UIImage(data: data) {
            Track.imageCache.setObject(uiImage, forKey: cacheKey)
            return uiImage
        }
        if let coverURL = coverURL {
            if !coverURL.hasPrefix("http") {
                let bundleURL = Bundle.main.bundleURL
                let moreSongsURL = bundleURL.appendingPathComponent("MoreSongs")
                let fileURL = moreSongsURL.appendingPathComponent(coverURL)
                if let uiImage = UIImage(contentsOfFile: fileURL.path) {
                    Track.imageCache.setObject(uiImage, forKey: cacheKey)
                    return uiImage
                }
                let mainFileURL = bundleURL.appendingPathComponent(coverURL)
                if let uiImage = UIImage(contentsOfFile: mainFileURL.path) {
                    Track.imageCache.setObject(uiImage, forKey: cacheKey)
                    return uiImage
                }
            }
        }
        return nil
    }

    func getCoverImage() -> Image? {
        if let uiImage = getUIImage() {
            return Image(uiImage: uiImage)
        }
        return nil
    }
    
}

extension UIImage {
    var averageBrightness: CGFloat {
        guard let cgImage = cgImage else { return 1.0 }
        guard let context = CGContext(data: nil,
                                      width: 1,
                                      height: 1,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return 1.0
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return 1.0 }
        let bitmap = data.bindMemory(to: UInt8.self, capacity: 4)
        let r = CGFloat(bitmap[0])
        let g = CGFloat(bitmap[1])
        let b = CGFloat(bitmap[2])
        return (r * 0.299 + g * 0.587 + b * 0.114) / 255.0
    }
}

struct LyricWord: Identifiable, Equatable, Codable {
    var id = UUID()
    let timestamp: Double
    let text: String
}

struct LyricLine: Identifiable, Equatable, Codable {
    var id = UUID()
    let timestamp: Double
    let text: String
    var words: [LyricWord]? = nil
}
