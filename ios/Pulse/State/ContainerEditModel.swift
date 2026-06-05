/// ContainerEditModel: view-model for creating or editing a container preset.
/// Manages form state (name, tare-weight text, optional photo), validation, and
/// orchestrates create/update plus photo upload/delete against the server.
/// Role: backing model for the container create/edit sheet.
import Foundation
import Observation
import UIKit

/// Observable view-model for the container create/edit form, including its photo lifecycle.
@Observable
final class ContainerEditModel {
    var name: String
    var tareWeightText: String
    var newPhotoJPEG: Data?
    var photoCleared: Bool = false

    private(set) var saving: Bool = false
    private(set) var error: PulseError?
    private(set) var savedContainerId: UUID?

    private let existing: Container?
    private weak var auth: AuthSession?

    /// Initializes the edit model, seeding form fields from an existing container if provided.
    /// Inputs:
    ///   - existing: the container being edited, or nil for create mode.
    ///   - auth: auth session used to construct an authenticated client.
    init(existing: Container? = nil, auth: AuthSession) {
        self.existing = existing
        self.auth = auth
        self.name = existing?.name ?? ""
        if let g = existing?.tareWeightG {
            self.tareWeightText = NumericInput.formatBare(g)
        } else {
            self.tareWeightText = ""
        }
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
            (Double(tareWeightText) ?? 0) > 0
    }

    var isExisting: Bool { existing != nil }

    var existingPhotoId: UUID? {
        guard let existing, existing.hasPhoto, !photoCleared else { return nil }
        return existing.id
    }

    /// Creates or updates the container and reconciles its photo (upload new, delete cleared, otherwise leave).
    /// Updates `saving`, `error`, and `savedContainerId` to drive UI feedback.
    func save() async {
        guard let client = auth?.makeClient(), let weight = Double(tareWeightText) else {
            error = .notSignedIn
            return
        }
        saving = true; defer { saving = false }
        do {
            let saved: Container
            if let existing {
                saved = try await client.updateContainer(id: existing.id, name: name, tareWeightG: weight)
            } else {
                saved = try await client.createContainer(name: name, tareWeightG: weight)
            }
            if let jpeg = newPhotoJPEG {
                try await client.uploadContainerPhoto(id: saved.id, jpegData: jpeg)
            } else if photoCleared, existing != nil {
                try await client.deleteContainerPhoto(id: saved.id)
            }
            savedContainerId = saved.id
            error = nil
        } catch let e as PulseError {
            if e == .unauthorized { auth?.handleUnauthorized() }
            error = e
        } catch {
            self.error = .server(status: -1)
        }
    }

    /// Stages a new container photo by JPEG-encoding the provided image.
    /// Inputs:
    ///   - uiImage: image chosen by the user.
    func setNewPhoto(uiImage: UIImage) {
        newPhotoJPEG = uiImage.jpegData(compressionQuality: 0.85)
        photoCleared = false
    }

    /// Marks the existing photo for deletion on next save and discards any staged new photo.
    func clearPhoto() {
        newPhotoJPEG = nil
        photoCleared = true
    }
}
