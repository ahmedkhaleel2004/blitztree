# S5 — Pin checksum for Codex installer

**Severity:** Low
**Source:** security-review-v0.5.1.md, finding S5

## Problem

`AgentSetup.installScript(_:)` for Codex fetches
`github.com/openai/codex/releases/latest/download/codex-aarch64-apple-darwin.tar.gz`
with no checksum or signature verification and installs it into
`~/.local/bin` — from where it runs as a Full-Disk-Access-inheriting
child of BlitzTree. `latest` is also non-reproducible: a new upstream
release changes behavior (or the artifact) silently.

## Fix

- Pin a version and verify the tarball's SHA-256 before extracting:

```sh
VER="0.x.y"; URL="https://github.com/openai/codex/releases/download/v$VER/codex-aarch64-apple-darwin.tar.gz"
T=$(mktemp -d)
curl -fsSL "$URL" -o "$t/codex.tar.gz"
echo "KNOWN_SHA256  $t/codex.tar.gz" | shasum -a 256 -c - || exit 1
tar -xzf "$t/codex.tar.gz" -C "$t"
```

- The known hash lives next to the script; a comment states the
  version it corresponds to and how to update it (download once,
  `shasum -a 256`, paste).
- Keep the Claude installer as-is (`claude.ai/install.sh` is
  Anthropic's own installer); optionally note its provenance.

## Acceptance criteria

- [ ] Installer verifies a pinned SHA-256 before extracting/moving.
- [ ] A mismatched checksum aborts with a clear error and installs
      nothing.
- [ ] Comment documents the pin-update procedure.
