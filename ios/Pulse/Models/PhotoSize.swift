/// Shared image-size variant for progress photos.
/// One enum used by both `ProgressPhotoClient` (which size to request from the
/// server) and `ProgressPhotoCache` (which variant to store/evict), so the two
/// layers can no longer drift and no translation shim is needed between them.
import Foundation

/// Image size variant for a progress photo: the full-resolution upload or the
/// server-generated thumbnail. The raw values (`"full"`, `"thumb"`) are sent
/// verbatim as the `size` query parameter and used as the on-disk cache suffix.
enum PhotoSize: String, CaseIterable {
    case full
    case thumb
}
