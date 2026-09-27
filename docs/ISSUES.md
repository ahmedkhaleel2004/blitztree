# Issue Ledger

In-repo tracker for work derived from the v0.5.1 security review
([security-review-v0.5.1.md](security-review-v0.5.1.md)). Each file is
one issue with acceptance criteria; status mirrors the checklist below.

| ID | Title | Severity | Status |
|----|-------|----------|--------|
| [S1](issues/S1-library-blocklist-gaps.md) | `~/Library` blocklist gaps (`LaunchAgents` & peers) | Medium | resolved |
| [S2](issues/S2-revalidate-at-action-time.md) | Re-validate guards at trash/command time (TOCTOU) | Medium | resolved |
| [S3](issues/S3-resolve-symlinks-in-guards.md) | Resolve symlinks before guard checks | Low | resolved |
| [S4](issues/S4-document-fda-inheritance.md) | Document FDA inheritance to child processes | Low | resolved (docs) |
| [S5](issues/S5-codex-installer-checksum.md) | Pin checksum for Codex installer | Low | resolved |
| [S6](issues/S6-command-exact-match.md) | Exact-match commands that take no argument | Low | resolved |
| [T1](issues/T1-ci-workflow.md) | CI: cargo test + Swift build on every push | — | resolved |
