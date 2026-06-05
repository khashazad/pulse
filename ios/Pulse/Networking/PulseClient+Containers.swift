/// `PulseClient` containers-domain endpoints: list/get/create/update/delete of
/// tare-weighted containers, plus multipart photo upload/delete and the
/// `nonisolated` photo-fetch request builder used by SwiftUI image loaders.
/// Pure code organization plus the standardized Codable request bodies; the
/// emitted JSON and behaviour are unchanged.
import Foundation

/// Request body for `POST /containers`. Encodes to `{"name", "tare_weight_g"}`.
private struct CreateContainerRequest: Encodable {
    let name: String
    let tareWeightG: Double

    enum CodingKeys: String, CodingKey {
        case name
        case tareWeightG = "tare_weight_g"
    }
}

/// Request body for `PATCH /containers/{id}`. Optional fields are encoded only
/// when present, so a nil value omits the key entirely (rather than sending
/// `null`) — matching the partial-update contract the server expects.
private struct UpdateContainerRequest: Encodable {
    let name: String?
    let tareWeightG: Double?

    enum CodingKeys: String, CodingKey {
        case name
        case tareWeightG = "tare_weight_g"
    }

    /// Encodes only the non-nil fields so omitted keys do not appear as `null`.
    /// Inputs:
    ///   - encoder: the encoder to write into.
    /// Outputs: nothing.
    /// Exceptions: rethrows any encoding error.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(name, forKey: .name)
        try container.encodeIfPresent(tareWeightG, forKey: .tareWeightG)
    }
}

extension PulseClient {
    /// Lists all containers for the current user.
    /// Outputs: the array unwrapped from the `ContainersList` envelope.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func listContainers() async throws -> [Container] {
        let url = try http.makeURL(path: "/containers", query: [])
        let list: ContainersList = try await fetch(url: url)
        return list.containers
    }

    /// Fetches a single container by id.
    /// Inputs:
    ///   - id: container UUID.
    /// Outputs: the `Container`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func getContainer(id: UUID) async throws -> Container {
        let url = try http.makeURL(path: "/containers/\(id.uuidString.lowercased())", query: [])
        return try await fetch(url: url)
    }

    /// Creates a container with a name and tare weight.
    /// Inputs:
    ///   - name: container display name.
    ///   - tareWeightG: empty-container weight in grams.
    /// Outputs: the newly created `Container`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func createContainer(name: String, tareWeightG: Double) async throws -> Container {
        let url = try http.makeURL(path: "/containers", query: [])
        let body = try JSONEncoder.pulseDefault().encode(
            CreateContainerRequest(name: name, tareWeightG: tareWeightG)
        )
        return try await sendJSON(url: url, method: "POST", body: body)
    }

    /// Patches a container with any non-nil fields supplied.
    /// Inputs:
    ///   - id: container UUID.
    ///   - name: new name, or `nil` to leave unchanged.
    ///   - tareWeightG: new tare weight in grams, or `nil` to leave unchanged.
    /// Outputs: the updated `Container`.
    /// Exceptions: `PulseError` on transport, auth, or decoding failure.
    func updateContainer(id: UUID, name: String?, tareWeightG: Double?) async throws -> Container {
        let url = try http.makeURL(path: "/containers/\(id.uuidString.lowercased())", query: [])
        let body = try JSONEncoder.pulseDefault().encode(
            UpdateContainerRequest(name: name, tareWeightG: tareWeightG)
        )
        return try await sendJSON(url: url, method: "PATCH", body: body)
    }

    /// Deletes a container.
    /// Inputs:
    ///   - id: container UUID.
    /// Exceptions: `PulseError` on transport or auth failure.
    func deleteContainer(id: UUID) async throws {
        let url = try http.makeURL(path: "/containers/\(id.uuidString.lowercased())", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        http.applyAuth(&req)
        try await sendNoBody(request: req)
    }

    /// Uploads a JPEG photo for a container as multipart/form-data.
    /// Inputs:
    ///   - id: container UUID.
    ///   - jpegData: encoded JPEG bytes.
    /// Exceptions: `PulseError` on transport, auth, or `.payloadTooLarge`.
    func uploadContainerPhoto(id: UUID, jpegData: Data) async throws {
        let url = try http.makeURL(path: "/containers/\(id.uuidString.lowercased())/photo", query: [])
        let boundary = "----PulseBoundary\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        http.applyAuth(&req)
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = HTTPCore.multipartBody(
            boundary: boundary,
            fields: [],
            file: (fieldName: "file", filename: "photo.jpg", mime: "image/jpeg", data: jpegData)
        )
        try await sendNoBody(request: req)
    }

    /// Deletes a container's photo.
    /// Inputs:
    ///   - id: container UUID.
    /// Exceptions: `PulseError` on transport or auth failure.
    func deleteContainerPhoto(id: UUID) async throws {
        let url = try http.makeURL(path: "/containers/\(id.uuidString.lowercased())/photo", query: [])
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        http.applyAuth(&req)
        try await sendNoBody(request: req)
    }

    /// Builds an authenticated `URLRequest` that fetches a container's photo
    /// at the requested size. Marked `nonisolated` so SwiftUI image loaders
    /// can call it synchronously off the actor.
    /// Inputs:
    ///   - id: container UUID.
    ///   - size: requested image size variant.
    /// Outputs: the prepared `URLRequest` with bearer auth attached.
    nonisolated func containerPhotoRequest(id: UUID, size: ContainerPhotoSize) -> URLRequest {
        let photoURL = http.baseURL.appendingPathComponent("/containers/\(id.uuidString.lowercased())/photo")
        guard
            var comps = URLComponents(url: photoURL, resolvingAgainstBaseURL: false)
        else {
            preconditionFailure("containerPhotoRequest: malformed photo URL \(photoURL)")
        }
        comps.queryItems = [URLQueryItem(name: "size", value: size.rawValue)]
        guard let url = comps.url else {
            preconditionFailure("containerPhotoRequest: components produced no URL")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(http.sessionToken)", forHTTPHeaderField: "Authorization")
        return req
    }
}
