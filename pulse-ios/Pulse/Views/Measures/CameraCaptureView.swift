/// SwiftUI wrapper around `UIImagePickerController` for progress-photo capture.
///
/// Hosts `CameraCaptureView`, which presents the system camera (or falls back
/// to the photo library when no camera is available) and reports the captured
/// image or a cancellation back to the SwiftUI caller. Used by the Measures
/// → Photos capture flow.
import SwiftUI
import UIKit

/// `UIViewControllerRepresentable` bridge that shows the camera and returns a `UIImage`.
///
/// Inputs:
/// - onCapture: callback invoked with the captured image when the user finishes.
/// - onCancel: callback invoked when the user dismisses without capturing.
struct CameraCaptureView: UIViewControllerRepresentable {
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    /// Creates the delegate coordinator wired back to this representable.
    ///
    /// Outputs: a `Coordinator` instance acting as the picker's delegate.
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    /// Builds the underlying picker, preferring `.camera` and falling back to library.
    ///
    /// Inputs:
    /// - context: SwiftUI representable context supplying the coordinator.
    ///
    /// Outputs: a configured `UIImagePickerController`.
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController()
        p.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
        if p.sourceType == .camera {
            p.cameraDevice = .rear
        }
        p.allowsEditing = false
        p.delegate = context.coordinator
        return p
    }

    /// No-op; the underlying picker's configuration never changes after creation.
    ///
    /// Inputs:
    /// - uiViewController: the hosted picker.
    /// - context: SwiftUI representable context (unused).
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    /// Delegate that forwards camera capture/cancel events back to the parent view.
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraCaptureView
        /// Captures a reference to the owning representable.
        ///
        /// Inputs:
        /// - parent: the `CameraCaptureView` whose callbacks should fire.
        init(_ parent: CameraCaptureView) { self.parent = parent }

        /// `UIImagePickerControllerDelegate` hook: forwards the original image
        /// to `onCapture`, or `onCancel` if the image is missing.
        ///
        /// Inputs:
        /// - picker: the active picker controller.
        /// - info: media metadata; `originalImage` is read when present.
        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            } else {
                parent.onCancel()
            }
        }

        /// `UIImagePickerControllerDelegate` hook: forwards cancellation to `onCancel`.
        ///
        /// Inputs:
        /// - picker: the active picker controller.
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}
