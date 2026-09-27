import Foundation

// Custom model providers: any OpenAI- or Anthropic-compatible endpoint by its
// base URL, protocol, API key and model — relays, self-hosted servers (Ollama,
// LM Studio, vLLM) or hosted gateways. The plan these endpoints return is just
// a proposal: CleanupGuard re-checks everything, exactly as for the CLI agents,
// and BlitzTree itself performs every deletion. The endpoint never runs tools;
// it only writes the plan, which is a strictly smaller surface than a CLI
// agent's harness — there is nothing for it to escalate.

// MARK: - Provider model

/// Wire format of the endpoint. `rawValue` is the settings identifier.
nonisolated enum APIProtocol: String, Codable, CaseIterable, Identifiable {
    case openAIChat
    case openAIResponses
    case anthropic

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openAIChat: return "OpenAI Chat Completions"
        case .openAIResponses: return "OpenAI Responses"
        case .anthropic: return "Anthropic Messages"
        }
    }

    /// Endpoint path appended to the provider's base URL. A base URL that
    /// already ends in /v1 (the common convention) is not doubled.
    func path(for baseURL: URL) -> URL {
        let endsInV1 = baseURL.path.hasSuffix("/v1")
        switch self {
        case .openAIChat: return baseURL.appending(path: "chat/completions")
        case .openAIResponses: return baseURL.appending(path: "responses")
        case .anthropic: return baseURL.appending(path: endsInV1 ? "messages" : "v1/messages")
        }
    }
}

nonisolated struct LLMProvider: Identifiable, Codable, Sendable, Equatable {
    /// Lowercase identifier, a letter first; names the provider in requests
    /// and its credential in the Keychain.
    var id: String
    var displayName: String
    var baseURL: URL
    var api: APIProtocol
    /// The model to ask for plans. The picker lists fetched IDs; unlisted IDs
    /// can be typed directly.
    var model: String
}

/// Providers and their API keys. Providers live in UserDefaults; keys live in
/// the Keychain, keyed `dev.ahmed.blitztree.<provider id>` — never in prefs.
@MainActor
@Observable
final class ProviderStore {
    static let shared = ProviderStore()

    private(set) var providers: [LLMProvider] = []

    private static let defaultsKey = "bz.providers"
    nonisolated private static let servicePrefix = "dev.ahmed.blitztree."

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([LLMProvider].self, from: data) {
            providers = saved
        }
    }

    func save(_ provider: LLMProvider, key: String?) {
        providers.removeAll { $0.id == provider.id }
        providers.append(provider)
        persist()
        if let key, !key.isEmpty { Self.setKey(key, for: provider.id) }
    }

    func delete(_ provider: LLMProvider) {
        providers.removeAll { $0.id == provider.id }
        persist()
        Self.deleteKey(for: provider.id)
    }

    func key(for id: String) -> String? { Self.getKey(for: id) }

    private func persist() {
        UserDefaults.standard.set(try? JSONEncoder().encode(providers), forKey: Self.defaultsKey)
    }

    // MARK: Keychain

    nonisolated static func setKey(_ key: String, for id: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + id,
            kSecAttrAccount as String: "api-key",
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    nonisolated static func getKey(for id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + id,
            kSecAttrAccount as String: "api-key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    nonisolated static func deleteKey(for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + id,
            kSecAttrAccount as String: "api-key",
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - The streaming plan request

/// What a provider run reports, mapped 1:1 onto the CLI agents' event
/// pipeline by the caller: cards as they are written, then the plan.
nonisolated enum LLMEvent: Sendable {
    case item(PlanItemSpec)
    case plan(summary: String, items: [PlanItemSpec])
    case failed(String)
}

/// Speaks one of the three wire protocols above and turns the answer into
/// events. Streaming SSE is the happy path; a plain (non-streaming) JSON
/// body and fenced/prose-wrapped JSON are both handled, because real
/// endpoints and real models do all of it.
nonisolated final class LLMPlanClient {
    private let provider: LLMProvider
    private let apiKey: String
    private var task: Task<Void, Never>?

    init(provider: LLMProvider, apiKey: String) {
        self.provider = provider
        self.apiKey = apiKey
    }

    func cancel() { task?.cancel() }

    func plan(_ prompt: String, emit: @escaping @Sendable (LLMEvent) -> Void) {
        task = Task { [provider, apiKey] in
            var parser = PartialPlanParser()
            do {
                // The network layer yields deltas; the parser mutates only
                // here, in the task body, where the isolation checker can
                // follow it.
                var full = ""
                for try await event in Self.streamEvents(provider: provider, apiKey: apiKey, prompt: prompt) {
                    switch event {
                    case .delta(let delta):
                        full += delta
                        for item in parser.append(delta) { emit(.item(item)) }
                    case .done:
                        // The finished text is authoritative when it decodes —
                        // strict JSON, fenced JSON, or prose around the object.
                        if let decoded = PlanJSON.decode(text: full) {
                            emit(.plan(summary: decoded.0, items: decoded.1))
                        } else if parser.hasInput {
                            // Deltas streamed but the strict JSON never closed
                            // (or a non-SSE body never arrived): the partial
                            // cards stand.
                            emit(.failed("The reply was not valid plan JSON."))
                        } else {
                            emit(.failed("The endpoint returned no plan."))
                        }
                        return
                    }
                }
            } catch is CancellationError {
            } catch let error as PlanError {
                emit(.failed(error.errorDescription ?? "The request failed."))
            } catch {
                emit(.failed(error.localizedDescription))
            }
        }
    }

    /// What the network layer reports: one text delta per SSE event, then
    /// `done` once the body is exhausted (non-SSE bodies surface their whole
    /// message as one delta).
    nonisolated private enum StreamEvent: Sendable {
        case delta(String)
        case done
    }

    /// One request as a stream of deltas.
    private static func streamEvents(provider: LLMProvider, apiKey: String, prompt: String) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [provider, apiKey] in
                do {
                    try await Self.stream(provider: provider, apiKey: apiKey, prompt: prompt) { delta in
                        continuation.yield(.delta(delta))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func stream(provider: LLMProvider, apiKey: String, prompt: String,
                               onDelta: @escaping @Sendable (String) -> Void) async throws {
        let url = provider.api.path(for: provider.baseURL)
        var request = URLRequest(url: url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any]
        switch provider.api {
        case .openAIChat:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            // json_mode is the widely supported floor for OpenAI-compatible
            // endpoints (Ollama, vLLM, gateways); the schema text in the
            // prompt carries the structure.
            body = [
                "model": provider.model, "stream": true,
                "response_format": ["type": "json_object"],
                "messages": [["role": "user", "content": prompt]],
            ]
        case .openAIResponses:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            body = ["model": provider.model, "stream": true, "input": prompt]
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            body = [
                "model": provider.model, "stream": true, "max_tokens": 8192,
                "messages": [["role": "user", "content": prompt]],
            ]
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Read the error body for the message endpoints usually send.
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 4096 { break }
            }
            throw PlanError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }

        var sawSSE = false
        var rawBody = ""
        // Server-sent events: `data:` lines, JSON payloads per protocol.
        for try await line in bytes.lines {
            rawBody += line + "\n"
            guard line.hasPrefix("data:") else { continue }
            sawSSE = true
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any] else { continue }
            if let delta = Self.delta(in: obj, api: provider.api) {
                onDelta(delta)
            }
        }
        // Endpoints that ignore `stream: true` answer with one plain JSON
        // body. Chat shape: the plan is inside choices[0].message.content.
        if !sawSSE {
            if let obj = try? JSONSerialization.jsonObject(with: Data(rawBody.utf8)) as? [String: Any],
               let choices = obj["choices"] as? [[String: Any]],
               let content = (choices.first?["message"] as? [String: Any])?["content"] as? String {
                onDelta(content)
            } else {
                // Some relays answer with the plan object itself.
                onDelta(rawBody)
            }
        }
    }

    /// The one text delta of an event, whatever the wire format.
    private static func delta(in obj: [String: Any], api: APIProtocol) -> String? {
        switch api {
        case .openAIChat:
            let choices = obj["choices"] as? [[String: Any]] ?? []
            return (choices.first?["delta"] as? [String: Any])?["content"] as? String
        case .openAIResponses:
            return obj["delta"] as? String
        case .anthropic:
            guard (obj["type"] as? String) == "content_block_delta" else { return nil }
            return (obj["delta"] as? [String: Any])?["text"] as? String
        }
    }
}

enum PlanError: Error { case http(Int, String) }

extension PlanError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .http(code, body):
            let line = body.split(separator: "\n").first ?? ""
            return "HTTP \(code)\(line.isEmpty ? "" : ": \(line.prefix(200))")"
        }
    }
}
