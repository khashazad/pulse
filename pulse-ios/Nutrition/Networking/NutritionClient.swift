import Foundation

actor NutritionClient {
    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let decoder: JSONDecoder

    init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.decoder = JSONDecoder.nutritionDefault()
    }

    func summary(date: Date) async throws -> DailySummary {
        let path = "/summary/\(DateOnly.string(from: date))"
        let url = try makeURL(path: path, query: [URLQueryItem(name: "user_key", value: Constants.userKey)])
        return try await fetch(url: url)
    }

    func logs(from: Date, to: Date) async throws -> LogsList {
        let url = try makeURL(
            path: "/logs",
            query: [
                URLQueryItem(name: "from", value: DateOnly.string(from: from)),
                URLQueryItem(name: "to", value: DateOnly.string(from: to)),
                URLQueryItem(name: "user_key", value: Constants.userKey),
            ]
        )
        return try await fetch(url: url)
    }

    // MARK: - private

    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw NutritionError.notConfigured
        }
        comps.queryItems = query
        guard let url = comps.url else { throw NutritionError.notConfigured }
        return url
    }

    private func fetch<T: Decodable>(url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let urlError as URLError {
            throw NutritionError.network(urlError)
        }

        guard let http = response as? HTTPURLResponse else {
            throw NutritionError.server(status: -1)
        }

        switch http.statusCode {
        case 200..<300:
            do {
                return try decoder.decode(T.self, from: data)
            } catch let decodingError {
                throw NutritionError.decoding(String(describing: decodingError))
            }
        case 401, 403:
            throw NutritionError.unauthorized
        case 404:
            throw NutritionError.notFound
        case 500...:
            throw NutritionError.server(status: http.statusCode)
        default:
            throw NutritionError.server(status: http.statusCode)
        }
    }
}
