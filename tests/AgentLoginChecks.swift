import Darwin
import Foundation

/// Claude and Codex print an authorize URL and expect a terminal. Sign-in has
/// to open that URL itself, and only that URL.
@main
struct AgentLoginChecks {
    @MainActor
    static func main() async {
        checkParser()
        await checkSession()
        print("AgentLoginChecks passed")
    }

    private static func checkParser() {
        let claude = """
        Opening browser to sign in…
        If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&response_type=code
        Paste code here if prompted >
        """
        let claudeURL = AgentLogin.url(in: claude)
        precondition(claudeURL?.host == "claude.com", "claude authorize host")
        precondition(claudeURL?.path == "/cai/oauth/authorize", "claude authorize path")
        precondition(claudeURL?.query?.contains("redirect_uri=") == true,
                     "the encoded redirect stays inside the authorize query")

        let codex = """
        Starting local login server on http://localhost:1455.
        If your browser did not open, navigate to this URL to authenticate: https://auth.openai.com/oauth/authorize?client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&code_challenge=abc&code_challenge_method=S256
        On a remote or headless machine? Use `codex login --device-auth` instead.
        """
        let codexURL = AgentLogin.url(in: codex)
        precondition(codexURL?.host == "auth.openai.com", "codex authorize host")
        precondition(codexURL?.path == "/oauth/authorize", "codex authorize path")
        precondition(AgentLogin.url(in: "Starting local login server on http://localhost:1455") == nil,
                     "the localhost callback is not the page to open")

        let ansi = "\u{1B}[32mhttps://claude.ai/oauth/authorize?x=1\u{1B}[0m"
        precondition(AgentLogin.url(in: ansi)?.host == "claude.ai", "ANSI around the URL")

        let mixed = "https://example.com/oauth/authorize https://accounts.anthropic.com/oauth/authorize?x=1"
        precondition(AgentLogin.url(in: mixed)?.host == "accounts.anthropic.com",
                     "skip a non-auth host and take the next authorize URL")

        let rejected = [
            "https://example.com/oauth/authorize",
            "http://auth.openai.com/oauth/authorize",
            "https://user:pw@auth.openai.com/oauth/authorize?x=1",
            "https://docs.anthropic.com/en/docs/claude-code",
            "https://platform.claude.com/docs/intro",
            "https://auth.openai.com.evil.com/oauth/authorize",
            "https://notopenai.com/oauth/authorize",
            "https://evilclaude.com/oauth/authorize",
            "https://claude.com/docs/oauth-overview",
            "file:///tmp/oauth/authorize",
            "",
        ]
        for sample in rejected {
            precondition(AgentLogin.url(in: sample) == nil, "must reject: \(sample)")
        }
    }

    @MainActor
    private static func checkSession() async {
        let directory = NSTemporaryDirectory()

        let tty = OpenBox()
        let ttyResult = await AgentLogin.run(
            executable: "/bin/sh",
            arguments: ["-c", "if [ -t 1 ]; then echo 'https://auth.openai.com/oauth/authorize?tty=1'; else echo not-a-tty >&2; exit 2; fi"],
            environmentPath: "/usr/bin:/bin",
            currentDirectory: directory,
            open: { tty.add($0) })
        precondition(ttyResult.status == 0, "sign-in stdio must be a terminal, status \(ttyResult.status) \(ttyResult.detail ?? "")")
        precondition(tty.urls.map(\.host) == ["auth.openai.com"], "open the authorize URL from a tty")

        let split = OpenBox()
        let splitScript = #"printf '%s' 'https://auth.openai.com/oa'; sleep 0.3; printf '%s\n' 'uth/authorize?split=1'"#
        let splitResult = await AgentLogin.run(
            executable: "/bin/sh",
            arguments: ["-c", splitScript],
            environmentPath: "/usr/bin:/bin",
            currentDirectory: directory,
            open: { split.add($0) })
        precondition(splitResult.status == 0, "split write should exit 0")
        precondition(split.urls.count == 1, "a URL split across reads is opened once")
        precondition(split.urls.first?.path == "/oauth/authorize", "split URL path")
        precondition(split.urls.first?.query?.contains("split=1") == true, "split URL query")

        let twice = OpenBox()
        _ = await AgentLogin.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo 'https://claude.com/cai/oauth/authorize?x=1'; echo 'https://claude.com/cai/oauth/authorize?x=1'"],
            environmentPath: "/usr/bin:/bin",
            currentDirectory: directory,
            open: { twice.add($0) })
        precondition(twice.urls.count == 1, "the same authorize URL is opened once")

        let stderr = OpenBox()
        _ = await AgentLogin.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo 'https://claude.com/cai/oauth/authorize?from=stderr' >&2"],
            environmentPath: "/usr/bin:/bin",
            currentDirectory: directory,
            open: { stderr.add($0) })
        precondition(stderr.urls.count == 1, "an authorize URL on stderr is opened")
        precondition(stderr.urls.first?.host == "claude.com", "stderr URL host")

        let rejected = OpenBox()
        let rejectedResult = await AgentLogin.run(
            executable: "/bin/sh",
            arguments: ["-c", "echo 'https://example.com/oauth/authorize' >&2; echo 'sign-in failed'; exit 1"],
            environmentPath: "/usr/bin:/bin",
            currentDirectory: directory,
            open: { rejected.add($0) })
        precondition(rejected.urls.isEmpty, "a non-auth URL is not opened")
        precondition(rejectedResult.status == 1, "failed stub exits 1")
        precondition(rejectedResult.detail == "sign-in failed",
                     "the CLI's own error is kept, got \(rejectedResult.detail ?? "nil")")
        precondition(rejectedResult.detail?.contains("https://") != true, "the error must not repeat a URL")

        // A grandchild that keeps the terminal open after the CLI exits used to
        // hold the wait until the grandchild died.
        let held = OpenBox()
        let heldStart = Date()
        let heldResult = await AgentLogin.run(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 6 & echo 'https://auth.openai.com/oauth/authorize?held=1'"],
            environmentPath: "/usr/bin:/bin",
            currentDirectory: directory,
            open: { held.add($0) })
        let heldFor = Date().timeIntervalSince(heldStart)
        precondition(heldResult.status == 0 && held.urls.count == 1, "the URL was still opened: \(heldResult)")
        precondition(heldFor < 5, "the wait after exit is bounded, took \(heldFor)s")

        // A sign-in nobody finishes is cut off at the injected limit.
        let hungStart = Date()
        let hung = await AgentLogin.run(
            executable: "/bin/sh", arguments: ["-c", "sleep 30"], environmentPath: "/usr/bin:/bin",
            currentDirectory: directory, open: { _ in }, timeout: 1)
        precondition(hung.status == -1 && hung.detail?.contains("timed out") == true, "\(hung)")
        precondition(Date().timeIntervalSince(hungStart) < 6, "bounded by the injected timeout")

        // Cancelling the task (Cancel in the panel) ends the CLI.
        let pidFile = URL(fileURLWithPath: directory).appendingPathComponent("login-pid-\(UUID().uuidString)")
        let cancelled = Task { @MainActor in
            await AgentLogin.run(
                executable: "/bin/sh", arguments: ["-c", "echo $$ > \(pidFile.path); exec sleep 60"],
                environmentPath: "/usr/bin:/bin", currentDirectory: directory, open: { _ in })
        }
        var pid: pid_t?
        for _ in 0..<250 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let value = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { pid = value; break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        precondition(pid != nil, "the CLI started")
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        try? FileManager.default.removeItem(at: pidFile)
        precondition(cancelledResult.status == -1, "\(cancelledResult)")
        precondition(kill(pid!, 0) == -1 && errno == ESRCH, "the cancelled CLI is gone and reaped")

        // A CLI that is not there fails cleanly.
        let missing = await AgentLogin.run(
            executable: directory + "/no-such-cli", arguments: [], environmentPath: "/usr/bin:/bin",
            currentDirectory: directory, open: { _ in })
        precondition(missing.status == -1 && missing.detail != nil, "\(missing)")
    }
}

private nonisolated final class OpenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    func add(_ url: URL) {
        lock.lock()
        stored.append(url)
        lock.unlock()
    }
    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
