# F1 — Custom model providers (any OpenAI/Anthropic-compatible endpoint)

Implemented in commit `cbda546`.

## What

The Clean Up panel no longer requires Claude Code or Codex. Settings →
Model Providers lets the user add any endpoint by its base URL, protocol
and key:

- Provider ID (lowercase, letter first — names the credential in the
  Keychain)
- Display name
- Base URL (e.g. `https://gateway.example/v1`)
- API protocol: OpenAI Chat Completions / OpenAI Responses / Anthropic
  Messages
- API key (stored in the Keychain, never in prefs)
- Model — fetched from the endpoint's `/models` where available; any ID
  can be typed directly

This covers relays, self-hosted servers (Ollama at
`http://localhost:11434/v1`, LM Studio, vLLM) and hosted gateways.

## Security posture (unchanged)

The endpoint **never runs tools**. It receives only the prompt (folder
paths and sizes, never file contents) and answers with plan JSON. All
the guarantees live in app code and are identical for every planner:

- `CleanupGuard` re-validates every path and command at plan time and
  again at action time
- Two-step delete (Trash → delete for good) is performed by BlitzTree,
  never by the model
- Streaming SSE parsing feeds the same event pipeline as the CLI
  agents, so the run panel behaves identically

Selected planner is `bz.engine` (`claude` / `codex` /
`provider:<id>`); the launch scan auto-starts it when ready.

# F2 — Multilingual UI

Implemented as classic `.strings` tables (`app/*.lproj/Localizable.strings`)
— the right mechanism for this project's hand-rolled `swiftc` build, where
`.xcstrings` catalogs are unavailable. SwiftUI string literals look up
`Localizable.strings` automatically, so views need almost no changes.

Languages: English (source), Turkish, German, French, Spanish, Simplified
Chinese, Japanese.

A Language picker in Settings → General writes `AppleLanguages`
(per-user); it applies at next launch and offers a relaunch button. The
agent prompt stays English by design: the LLM plans in English while the
UI follows the user's language.
