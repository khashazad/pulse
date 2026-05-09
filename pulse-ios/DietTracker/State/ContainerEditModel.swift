import Foundation
import Observation
import UIKit

@Observable
final class ContainerEditModel {
    var name: String
    var tareWeightText: String
    var newPhotoJPEG: Data?
    var photoCleared: Bool = false

    private(set) var saving: Bool = false
    private(set) var error: DietTrackerError?
    private(set) var savedContainerId: UUID?

    private let existing: Container?
    private weak var auth: AuthSession?

    init(existing: Container? = nil, auth: AuthSession) {
        self.existing = existing
        self.auth = auth
        self.name = existing?.name ?? ""
        if let g = existing?.tareWeightG {
            self.tareWeightText = String(format: "%g", g)
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

    func save() async {
        guard let client = auth?.makeClient(), let weight = Double(tareWeightText) else {
            error = .notConfigured
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
        } catch let e as DietTrackerError {
            error = e
        } catch {
            self.error = .server(status: -1)
        }
    }

    func setNewPhoto(uiImage: UIImage) {
        newPhotoJPEG = uiImage.jpegData(compressionQuality: 0.85)
        photoCleared = false
    }

    func clearPhoto() {
        newPhotoJPEG = nil
        photoCleared = true
    }
}
