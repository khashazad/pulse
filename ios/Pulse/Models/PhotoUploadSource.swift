/// Source file data and preview information for one photo upload.
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Keeps original image bytes separate from the decoded preview image.
struct PhotoUploadSource {
    let data: Data
    let previewImage: UIImage
    let filename: String
    let mimeType: String

    /// Creates an upload source without changing the encoded image data.
    init?(data: Data, fallbackType: UTType? = nil) {
        guard let previewImage = UIImage(data: data) else { return nil }
        let type = Self.detectedType(for: data) ?? fallbackType
        let fileExtension = type?.preferredFilenameExtension ?? "bin"
        self.data = data
        self.previewImage = previewImage
        self.filename = "photo.\(fileExtension)"
        self.mimeType = type?.preferredMIMEType ?? "application/octet-stream"
    }

    /// Creates a maximum-quality JPEG source when a camera API supplies pixels only.
    init?(cameraImage: UIImage) {
        guard let data = cameraImage.jpegData(compressionQuality: 1.0) else { return nil }
        self.data = data
        self.previewImage = cameraImage
        self.filename = "photo.jpg"
        self.mimeType = "image/jpeg"
    }

    /// Detects the encoded image type from ImageIO metadata.
    private static func detectedType(for data: Data) -> UTType? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) else { return nil }
        return UTType(identifier as String)
    }
}
