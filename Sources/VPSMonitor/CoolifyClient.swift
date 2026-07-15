import Foundation

struct CoolifyClient {
    enum APIError: LocalizedError {
        case invalidURL, missingToken, http(Int, String), invalidResponse
        var errorDescription: String? {
            switch self {
            case .invalidURL: "La URL de Coolify no es válida."
            case .missingToken: "Introduce un token de lectura de Coolify."
            case .http(let status, let message): "Coolify respondió \(status): \(message)"
            case .invalidResponse: "La respuesta de Coolify no tiene el formato esperado."
            }
        }
    }

    func fetchProjects(baseURL: String, token: String) async throws -> [CoolifyProject] {
        guard !token.isEmpty else { throw APIError.missingToken }
        guard var root = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)), root.scheme != nil else { throw APIError.invalidURL }
        if root.path.hasSuffix("/") { root.deleteLastPathComponent() }
        if !root.path.hasSuffix("/api/v1") { root.append(path: "api/v1") }
        let apiRoot = root

        async let projectListRequest = get(apiRoot.appending(path: "projects"), token: token)
        async let applicationsRequest = get(apiRoot.appending(path: "applications"), token: token)
        async let servicesRequest = get(apiRoot.appending(path: "services"), token: token)
        async let databasesRequest = get(apiRoot.appending(path: "databases"), token: token)

        let projectList = try await projectListRequest.arrayValue ?? []
        let applications = try await applicationsRequest.arrayValue ?? []
        let services = try await servicesRequest.arrayValue ?? []
        let databases = try await databasesRequest.arrayValue ?? []

        let details = try await withThrowingTaskGroup(of: JSONValue.self) { group in
            for summary in projectList {
                guard let id = summary.string("uuid") else { continue }
                group.addTask {
                    try await get(apiRoot.appending(path: "projects/\(id)"), token: token)
                }
            }
            var values: [JSONValue] = []
            for try await detail in group { values.append(detail) }
            return values
        }

        return parseProjects(details: details,
                             summaries: projectList,
                             applications: applications,
                             services: services,
                             databases: databases)
    }

    func parseProjects(details: [JSONValue], summaries: [JSONValue], applications: [JSONValue], services: [JSONValue], databases: [JSONValue]) -> [CoolifyProject] {
        let inventory = parseInventory(applications, type: "Aplicación")
            + parseInventory(services, type: "Servicio")
            + parseInventory(databases, type: "Base de datos")
        let summariesByID = Dictionary(uniqueKeysWithValues: summaries.compactMap { value -> (String, JSONValue)? in
            guard let id = value.string("uuid") else { return nil }
            return (id, value)
        })
        return details.map { detail in
            let id = detail.string("uuid") ?? UUID().uuidString
            return parseProject(detail, fallback: summariesByID[id] ?? detail, inventory: inventory)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func get(_ url: URL, token: String) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(decoding: data, as: UTF8.self)
            throw APIError.http(http.statusCode, String(body.prefix(180)))
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func parseProject(_ detail: JSONValue, fallback: JSONValue, inventory: [InventoryResource]) -> CoolifyProject {
        let id = detail.string("uuid") ?? fallback.string("uuid") ?? UUID().uuidString
        let name = detail.string("name") ?? fallback.string("name") ?? "Proyecto"
        let environments = detail.array("environments")?.map { parseEnvironment($0, inventory: inventory) } ?? []
        return CoolifyProject(id: id, name: name, environments: environments)
    }

    private func parseEnvironment(_ value: JSONValue, inventory: [InventoryResource]) -> CoolifyEnvironment {
        let id = value.string("uuid") ?? String(value.int("id") ?? 0)
        let name = value.string("name") ?? "Entorno"
        let groups = [("applications", "Aplicación"), ("services", "Servicio"), ("databases", "Base de datos"),
                      ("postgresqls", "PostgreSQL"), ("mysqls", "MySQL"), ("mariadbs", "MariaDB"),
                      ("mongodbs", "MongoDB"), ("redis", "Redis"), ("keydbs", "KeyDB"), ("dragonflies", "Dragonfly")]
        var resources = groups.flatMap { key, type in
            (value.array(key) ?? []).map { resource in
                parseResource(resource, type: type)
            }
        }
        if let numericID = value.int("id") {
            resources += inventory.filter { $0.environmentID == numericID }.map(\.resource)
        }
        resources = Dictionary(grouping: resources, by: \.id).compactMap(\.value.first)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return CoolifyEnvironment(id: id, name: name, resources: resources)
    }

    private func parseInventory(_ values: [JSONValue], type: String) -> [InventoryResource] {
        values.compactMap { value in
            guard let environmentID = value.int("environment_id") else { return nil }
            let resolvedType = value.string("type") ?? type
            return InventoryResource(environmentID: environmentID, resource: parseResource(value, type: resolvedType))
        }
    }

    private func parseResource(_ value: JSONValue, type: String) -> CoolifyResource {
        CoolifyResource(id: value.string("uuid") ?? UUID().uuidString,
                        name: value.string("name") ?? type,
                        type: type,
                        status: value.string("status") ?? "unknown",
                        url: value.string("fqdn").flatMap(normalizedURL))
    }

    private func normalizedURL(_ string: String) -> URL? {
        let first = string.split(separator: ",").first.map(String.init) ?? string
        return URL(string: first.contains("://") ? first : "https://\(first)")
    }
}

private struct InventoryResource {
    let environmentID: Int
    let resource: CoolifyResource
}

enum JSONValue: Decodable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "JSON no compatible") }
    }
    var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    func string(_ key: String) -> String? { if case .object(let o) = self, case .string(let v) = o[key] { v } else { nil } }
    func int(_ key: String) -> Int? { if case .object(let o) = self, case .number(let v) = o[key] { Int(v) } else { nil } }
    func array(_ key: String) -> [JSONValue]? { if case .object(let o) = self, case .array(let v) = o[key] { v } else { nil } }
}
