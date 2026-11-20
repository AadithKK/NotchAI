import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// In-memory encoding of captured images.
///
/// Pure ImageIO work: no ScreenCaptureKit, no filesystem. Extracted from `ScreenshotService` so the
/// format mapping and the encoded bytes can be tested offline with synthesized images.
enum ScreenshotEncoding {
    /// JPEG quality used for `.jpeg` screenshots.
    static let jpegCompressionQuality: CGFloat = 0.9

    static func utType(for format: ScreenshotFormat) -> UTType {
        switch format {
        case .png: return .png
        case .jpeg: return .jpeg
        }
    }

    /// Encodes `image` as `format` and returns the file bytes. Never touches the filesystem.
    static func data(for image: CGImage, format: ScreenshotFormat) throws -> Data {
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData as CFMutableData,
            utType(for: format).identifier as CFString,
            1,
            nil
        ) else {
            throw ScreenshotError.encodingFailed
        }

        var properties: [CFString: Any] = [:]
        if format == .jpeg {
            properties[kCGImageDestinationLossyCompressionQuality] = jpegCompressionQuality
        }
        CGImageDestinationAddImage(
            destination,
            image,
            properties.isEmpty ? nil : properties as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotError.encodingFailed
        }

        let data = mutableData as Data
        guard !data.isEmpty else {
            throw ScreenshotError.encodingFailed
        }
        return data
    }
}
