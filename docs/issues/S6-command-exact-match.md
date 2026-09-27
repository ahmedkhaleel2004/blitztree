# S6 — Exact-match commands that take no argument

**Severity:** Low
**Source:** security-review-v0.5.1.md, finding S6

## Problem

`CleanupGuard.blockReason(command:)` accepts a plan command when it
equals an allowlisted command or *starts with* it (`hasPrefix`). For
argument-taking commands (`ollama rm <model>`) that is by design, but
it also admits extra trailing arguments and flags for every entry
(`uv cache clean --extra`, `pip cache purge anything`), which is wider
than "each tool's own cleanup command". The metacharacter ban is solid;
this is about argument discipline.

## Fix

Classify the allowlist:

- **No-argument commands** — exact string match only (after
  whitespace trim): `uv cache clean`, `uv cache prune`, `npm cache
  clean` (note: the prompt suggests `npm cache clean --force`; make
  that its own exact entry), `pnpm store prune`, `yarn cache clean`,
  `brew cleanup` (allow `brew cleanup` and the specific flag forms the
  prompt documents as separate exact entries), `pip cache purge`,
  `pip3 cache purge`, `go clean -cache`, `go clean -modcache`,
  `gem cleanup`, `conda clean`, `mamba clean`.
- **One-argument commands** — prefix match with exactly one trailing
  token: `ollama rm`, `brew autoremove` (none), `docker system prune`
  (allow `-f` as exact entry), `docker image prune` (`-f` exact),
  `docker builder prune` (`-f` exact), `docker container prune`,
  `xcrun simctl delete unavailable` (exact),
  `xcrun simctl runtime delete` (one token), `pod cache clean`
  (`--all` exact), `conda clean -a -y` (exact).
- Align `AgentPrompt.build`'s command list in the prompt with the same
  exact forms so the model and guard agree.

## Acceptance criteria

- [ ] Every allowlisted command is either exact-match or
      one-trailing-token, per the table above.
- [ ] Extra arguments/flags beyond the documented forms are rejected.
- [ ] Prompt and guard use the same command strings.
