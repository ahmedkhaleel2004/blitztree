import SwiftUI

// Settings (Cmd+,): language, the planner used by the Clean Up panel, and
// custom model providers — any OpenAI- or Anthropic-compatible endpoint by
// its base URL, protocol and key. Provider plans arrive over plain HTTPS;
// BlitzTree's own guards and two-step delete are identical for them and for
// the CLI agents.

// MARK: - Providers

struct ProvidersView: View {
    @State private var store = ProviderStore.shared
    @State private var editing: ProviderForm?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Custom model providers")
                    .font(.headline)
                Spacer()
                Button { editing = .new } label: {
                    Label("Add provider", systemImage: "plus")
                }
            }
            Text("Connect a relay, a self-hosted server, or any other OpenAI- or "
                 + "Anthropic-compatible endpoint by its base URL, protocol, and models.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if store.providers.isEmpty {
                Text("No custom providers. The Clean Up panel uses Claude Code or Codex "
                     + "when one is installed and signed in.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
            } else {
                List(store.providers) { provider in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.displayName)
                            Text("\(provider.model) · \(provider.baseURL.absoluteString)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Edit") { editing = .existing(provider) }
                        Button("Delete", role: .destructive) { store.delete(provider) }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
        .sheet(item: $editing) { form in
            ProviderFormView(initial: form)
        }
    }
}

/// What the sheet edits: a brand-new provider or an existing one.
enum ProviderForm: Identifiable {
    case new
    case existing(LLMProvider)
    var id: String { switch self { case .new: "new"; case .existing(let p): p.id } }
}

/// The add/edit sheet: provider ID, display name, base URL, protocol, key,
/// models — mirroring how other tools name these fields.
struct ProviderFormView: View {
    let initial: ProviderForm

    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var displayName = ""
    @State private var baseURL = ""
    @State private var api: APIProtocol = .openAIChat
    @State private var key = ""
    @State private var model = ""
    @State private var models: [String] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom model API")
                .font(.headline)
            field(String(localized: "Provider ID"), text: $id, placeholder: "acme-gateway",
                  caption: String(localized: "Lowercase identifier, starting with a letter, that uniquely names this provider in requests and as its credential name."))
            field(String(localized: "Display name"), text: $displayName, placeholder: String(localized: "Display name"))
            field(String(localized: "Base URL"), text: $baseURL, placeholder: "https://gateway.example/v1")
            Picker("API protocol", selection: $api) {
                ForEach(APIProtocol.allCases) { proto in
                    Text(proto.label).tag(proto)
                }
            }
            SecureField("Enter your API key", text: $key)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Models").font(.callout)
                    Spacer()
                    Button("Fetch available models") { Task { await fetchModels() } }
                        .disabled(baseURL.isEmpty)
                }
                if models.isEmpty {
                    Text("No models will be shown in the selector. Unlisted IDs can still be sent directly.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    Picker("Model", selection: $model) {
                        ForEach(models, id: \.self) { Text($0).tag($0) }
                        Text(model).tag(model) // keep a typed-but-unlisted ID
                    }
                }
                TextField("Model ID", text: $model, prompt: Text("gpt-4o-mini"))
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create provider") { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 520, alignment: .leading)
        .onAppear {
            if case .existing(let p) = initial {
                id = p.id; displayName = p.displayName; baseURL = p.baseURL.absoluteString
                api = p.api; model = p.model
                key = ProviderStore.getKey(for: p.id) ?? ""
            }
        }
    }

    private var isValid: Bool {
        // The id doubles as the Keychain credential name; keep it strict.
        id.range(of: "^[a-z][a-z0-9-]*$", options: .regularExpression) != nil
            && URL(string: baseURL)?.scheme != nil && !model.isEmpty
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String, caption: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout)
            TextField(placeholder, text: text, prompt: Text(placeholder))
            if let caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// GET /models (OpenAI shape) — a nicety; endpoints without it just stay
    /// on the typed model ID.
    private func fetchModels() async {
        error = nil
        guard let base = URL(string: baseURL) else { return }
        var request = URLRequest(url: base.appending(path: "models"))
        request.timeoutInterval = 15
        if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = obj["data"] as? [[String: Any]] {
                models = list.compactMap { $0["id"] as? String }.sorted()
            } else {
                error = String(localized: "Could not read a model list from this endpoint; type the ID.")
            }
        } catch {
            self.error = String(localized: "Could not fetch models: \(error.localizedDescription)")
        }
    }

    private func save() {
        guard let url = URL(string: baseURL) else { return }
        let provider = LLMProvider(id: id, displayName: displayName.isEmpty ? id : displayName,
                                   baseURL: url, api: api, model: model)
        ProviderStore.shared.save(provider, key: key.isEmpty ? nil : key)
        dismiss()
    }
}

// MARK: - Language

/// Languages BlitzTree ships strings for. `system` follows macOS; a picked
/// language applies at next launch (AppleLanguages).
let availableLanguages: [(code: String?, name: String)] = [
    (nil, String(localized: "Follow system")),
    ("en", "English"),
    ("tr", "Türkçe"),
    ("de", "Deutsch"),
    ("fr", "Français"),
    ("es", "Español"),
    ("zh-Hans", "简体中文"),
    ("ja", "日本語"),
]

struct GeneralSettingsView: View {
    @State private var language = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Language", selection: Binding(
                get: { language },
                set: { code in
                    language = code
                    if let code {
                        UserDefaults.standard.set([code], forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    }
                })) {
                ForEach(availableLanguages, id: \.code) { entry in
                    Text(entry.name).tag(entry.code)
                }
            }
            .frame(width: 280)
            if changed {
                HStack {
                    Text("Relaunch BlitzTree to apply the language.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Relaunch") { FDA.relaunch() }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 560, alignment: .leading)
    }

    private var changed: Bool {
        let current = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first
        return current != language
    }
}
