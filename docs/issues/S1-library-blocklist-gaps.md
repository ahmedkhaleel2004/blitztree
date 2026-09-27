# S1 — `~/Library` blocklist gaps (`LaunchAgents` and peers)

**Severity:** Medium
**Source:** security-review-v0.5.1.md, finding S1

## Problem

`CleanupGuard.protected` / `tooBroad` (`app/Agent.swift`) enumerate
forbidden paths, but a two-component path such as
`~/Library/LaunchAgents` passes the depth check
(`rel.split(separator: "/").count >= 2`) and is not an exact
`tooBroad` match, so it is not blocked. Paths *inside* such folders
(three components) pass as well. The prompt tells the model never to
touch whole `~/Library`, but the prompt is advisory only — enforcement
must live in `CleanupGuard`.

Folders that alter app behavior or persistence must never be
agent-cleanable, whatever the plan says.

## Fix

Extend `tooBroad` (exact-match, so named *subfolders* of genuinely
rebuildable caches still work) with at least:

```
Library/LaunchAgents      Library/LaunchDaemons
Library/Cookies           Library/Logs
Library/Saved Application State
Library/Spelling          Library/Frameworks
Library/PrivilegedHelperTools
Library/ScriptingAdditions
Library/Internet Plug-Ins Library/PreferencePanes
Library/Input Methods     Library/Fonts
Library/Services          Library/StartupItems
Library/Tokens            Library/Widgets
Library/Containers        Library/Group Containers
Library/Metadata          Library/Desktop Pictures
Library/Screen Savers     Library/Workflows
Library/Automator         Library/Contextual Menu Items
Library/Compositions      Library/DirectoryServices
```

Also `~/Library/Calendars`, `~/Library/Accounts`, `~/Library/Application
Scripts`.

## Acceptance criteria

- [x] `blockReason(path:)` returns a reason for every path above and
      anything inside them.
- [x] `~/Library/Caches/<tool>` style paths (named subfolder of an
      allowed parent) still pass when they match the cleanup kinds.
- [ ] A fixture test enumerates the list and asserts blocking.
      *(Swift has no test infrastructure in this repo; the blocklist is
      enforced in `CleanupGuard.neverClean` and checked by review only.)*
