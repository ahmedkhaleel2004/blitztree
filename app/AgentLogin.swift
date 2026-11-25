import Darwin
import Foundation

/// The authorize page a Claude or Codex CLI prints while it waits for the
/// browser to come back. Anything else in that transcript stays closed.
nonisolated enum AgentLogin {
    struct Result: Sendable, Equatable {
        var status: Int32
        /// A short CLI error with the authorize URL removed. Nil when it exited 0.
        var detail: String?
    }

    private static let hosts = ["claude.com", "claude.ai", "anthropic.com", "openai.com", "chatgpt.com"]
    private static let segments: Set<String> = ["oauth", "authorize", "device"]

    /// First https authorize URL in `transcript`.
    /// While more output may still arrive, pass `requireTerminator` so a URL
    /// cut off mid-query is not opened early.
    nonisolated static func url(in transcript: String, requireTerminator: Bool = false) -> URL? {
        // CRLF is one Swift character, so turn it into a newline before scanning.
        let text = stripANSI(transcript)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var search = text.startIndex
        while let range = text.range(of: "https://", range: search..<text.endIndex) {
            var end = range.lowerBound
            var terminated = false
            while end < text.endIndex {
                if isTerminator(text[end]) {
                    terminated = true
                    break
                }
                end = text.index(after: end)
            }
            // The tail may be a URL the next read will finish.
            if !terminated, requireTerminator { return nil }
            var raw = String(text[range.lowerBound..<end])
            while let last = raw.last, ".,;\"')>]".contains(last) { raw.removeLast() }
            if let url = allowlisted(raw) { return url }
            guard terminated, end < text.endIndex else { break }
            search = text.index(after: end)
        }
        return nil
    }

    nonisolated static func detail(from last: String, status: Int32) -> String? {
        guard status != 0 else { return nil }
        var line = stripANSI(last).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return "exit \(status)" }
        if line.contains("https://") || line.contains("http://") {
            line = withoutURLs(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { return "exit \(status)" }
        }
        if line.count > 180 { line = String(line.prefix(180)) }
        return line
    }

    /// Runs the CLI on a terminal when the system can allocate one (pipes
    /// otherwise), reads everything it prints, and opens the first
    /// allowlisted authorize URL. The wait is bounded by `timeout` and by a
    /// short drain grace once the CLI has exited (a grandchild that keeps the
    /// terminal open cannot hold sign-in up), and cancelling the calling task
    /// terminates and reaps the CLI.
    @MainActor
    static func run(executable: String, arguments: [String], environmentPath: String,
                    currentDirectory: String, open: @escaping @Sendable (URL) -> Void,
                    timeout: TimeInterval = 900) async -> Result {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = environmentPath
        // A traced or CI shell must not change the sign-in transcript.
        environment["SHELLOPTS"] = nil
        environment["BASH_ENV"] = nil
        environment["ENV"] = nil
        environment["CI"] = nil

        let session = AgentLoginSession(
            executable: executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            open: open,
            timeout: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                session.start { outcome in
                    continuation.resume(returning: outcome)
                }
            }
        } onCancel: {
            session.cancel()
        }
    }

    private nonisolated static func allowlisted(_ raw: String) -> URL? {
        guard (1...8192).contains(raw.count), raw.hasPrefix("https://") else { return nil }
        guard let parts = URLComponents(string: raw), parts.scheme == "https" else { return nil }
        if parts.user != nil || parts.password != nil { return nil }
        guard let host = parts.host?.lowercased(), hostAllowed(host) else { return nil }
        let partsOfPath = parts.path.lowercased().split(separator: "/").map(String.init)
        guard partsOfPath.contains(where: { segments.contains($0) }) else { return nil }
        return parts.url
    }

    private nonisolated static func hostAllowed(_ host: String) -> Bool {
        hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private nonisolated static func isTerminator(_ ch: Character) -> Bool {
        ch.isWhitespace || "\"'<>`".contains(ch)
    }

    private nonisolated static func stripANSI(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\u{1B}" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "[" {
                    var cursor = text.index(after: next)
                    while cursor < text.endIndex {
                        let ch = text[cursor]
                        cursor = text.index(after: cursor)
                        if ch.isLetter { break }
                    }
                    index = cursor
                    continue
                }
            }
            out.append(text[index])
            index = text.index(after: index)
        }
        return out
    }

    /// Drops http(s) tokens so a failure line can be shown without a URL.
    private nonisolated static func withoutURLs(_ text: String) -> String {
        var out = ""
        var search = text.startIndex
        while search < text.endIndex {
            let http = text.range(of: "http://", range: search..<text.endIndex)
            let https = text.range(of: "https://", range: search..<text.endIndex)
            let range: Range<String.Index>?
            switch (http, https) {
            case let (a?, b?): range = a.lowerBound <= b.lowerBound ? a : b
            case let (a?, nil): range = a
            case let (nil, b?): range = b
            default: range = nil
            }
            guard let range else {
                out += text[search...]
                break
            }
            out += text[search..<range.lowerBound]
            var end = range.upperBound
            while end < text.endIndex, !isTerminator(text[end]) { end = text.index(after: end) }
            search = end
        }
        return out
    }
}

/// Stdio and lifecycle for one sign-in run. A terminal makes `isatty` true,
/// which is what the CLIs check before they will open a browser themselves;
/// pipes still carry the URL when a terminal cannot be allocated.
private nonisolated final class AgentLoginSession: @unchecked Sendable {
    private static let spawnLock = NSLock()

    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let currentDirectory: String
    private let timeout: TimeInterval
    private let killGrace: TimeInterval = 1
    private let drainGrace: TimeInterval = 2

    private let queue = DispatchQueue(label: "blitztree.agent-login", qos: .userInitiated)
    private let process = Process()
    private let transcript: LoginTranscript
    private let tail = LoginTail()

    private let lock = NSLock()
    private var started = false
    private var pid: pid_t = 0
    private var exited = false
    private var exitStatus: Int32 = -1
    private var cancelRequested = false
    private var terminateRequested = false

    private var streams: [StreamReader] = []
    private var openStreams = 0
    private var timedOut = false
    private var finished = false
    private var timer: DispatchWorkItem?
    private var drainTimer: DispatchWorkItem?
    private var onFinish: (@Sendable (AgentLogin.Result) -> Void)?

    init(executable: String, arguments: [String], environment: [String: String],
         currentDirectory: String, open: @escaping @Sendable (URL) -> Void,
         timeout: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.timeout = timeout
        self.transcript = LoginTranscript(open: open)
    }

    func start(completion: @escaping @Sendable (AgentLogin.Result) -> Void) {
        lock.lock()
        if cancelRequested {
            lock.unlock()
            completion(AgentLogin.Result(status: -1, detail: "cancelled"))
            return
        }
        started = true
        onFinish = completion
        lock.unlock()

        var owned: [Int32] = []
        var childEnds: [Int32] = []
        func closeUnused() {
            for fd in owned + childEnds { Darwin.close(fd) }
        }

        Self.spawnLock.lock()
        defer { Self.spawnLock.unlock() }

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)

        var readFDs: [Int32] = []
        if let pty = PTY.open() {
            let handle = FileHandle(fileDescriptor: pty.slave, closeOnDealloc: false)
            process.standardInput = handle
            process.standardOutput = handle
            process.standardError = handle
            childEnds.append(pty.slave)
            owned.append(pty.master)
            readFDs.append(pty.master)
        } else {
            process.standardInput = FileHandle.nullDevice
            guard let out = makePipe(), let err = makePipe() else {
                closeUnused()
                completion(AgentLogin.Result(status: -1, detail: "Couldn't create pipes for sign-in."))
                return
            }
            process.standardOutput = FileHandle(fileDescriptor: out.write, closeOnDealloc: false)
            process.standardError = FileHandle(fileDescriptor: err.write, closeOnDealloc: false)
            childEnds.append(contentsOf: [out.write, err.write])
            owned.append(contentsOf: [out.read, err.read])
            readFDs.append(contentsOf: [out.read, err.read])
        }

        for fd in readFDs {
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            let reader = StreamReader(fd: fd, queue: queue, onData: { [self] data in
                transcript.feed(data)
                tail.feed(data)
            }, onEnd: { [self] in
                streamEnded()
            })
            streams.append(reader)
        }
        openStreams = streams.count

        process.terminationHandler = { [self] done in
            lock.lock()
            exited = true
            exitStatus = done.terminationStatus
            lock.unlock()
            queue.async { [self] in handleExit() }
        }

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            for reader in streams { reader.abandon() }
            streams = []
            openStreams = 0
            for fd in childEnds { Darwin.close(fd) }
            onFinish = nil
            completion(AgentLogin.Result(status: -1, detail: error.localizedDescription))
            return
        }

        for fd in childEnds { Darwin.close(fd) }
        lock.lock()
        pid = process.processIdentifier
        let stop = terminateRequested
        lock.unlock()

        for reader in streams { reader.resume() }
        queue.async { [self] in
            if !finished {
                let item = DispatchWorkItem { [self] in
                    guard !finished else { return }
                    timedOut = true
                    terminate()
                }
                timer = item
                queue.asyncAfter(deadline: .now() + max(0, timeout), execute: item)
            }
        }
        if stop { terminate() }
    }

    func cancel() {
        lock.lock()
        cancelRequested = true
        lock.unlock()
        terminate()
    }

    private func terminate() {
        lock.lock()
        guard started, !exited else { lock.unlock(); return }
        let target = pid
        if target <= 0 {
            terminateRequested = true
            lock.unlock()
            return
        }
        lock.unlock()

        let group = getpgid(target)
        let signalsGroup = group == target && group != getpgrp() && group > 1
        func send(_ signal: Int32) {
            if signalsGroup, Darwin.kill(-group, signal) == 0 { return }
            if stillRunning { Darwin.kill(target, signal) }
        }
        send(SIGTERM)
        queue.asyncAfter(deadline: .now() + killGrace) { [self] in
            if signalsGroup { Darwin.kill(-group, SIGKILL) } else if stillRunning { Darwin.kill(target, SIGKILL) }
            queue.asyncAfter(deadline: .now() + killGrace) { [self] in
                guard stillRunning else { return }
                abandon()
            }
        }
    }

    private var stillRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return started && !exited && pid > 0
    }

    private func abandon() {
        lock.lock()
        exited = true
        exitStatus = -1
        lock.unlock()
        handleExit()
    }

    private func handleExit() {
        guard !finished, drainTimer == nil else { return }
        if openStreams == 0 {
            finish()
            return
        }
        let item = DispatchWorkItem { [self] in
            guard !finished else { return }
            for reader in streams { reader.cancel() }
        }
        drainTimer = item
        queue.asyncAfter(deadline: .now() + drainGrace, execute: item)
    }

    private func streamEnded() {
        openStreams -= 1
        lock.lock()
        let gone = exited
        lock.unlock()
        if openStreams <= 0, gone { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        drainTimer?.cancel()
        process.terminationHandler = nil
        transcript.flush()

        lock.lock()
        let cancelled = cancelRequested
        let status = exitStatus
        lock.unlock()

        let result: AgentLogin.Result
        if cancelled {
            result = AgentLogin.Result(status: -1, detail: "cancelled")
        } else if timedOut {
            result = AgentLogin.Result(status: -1, detail: "timed out after \(Int(timeout)) seconds")
        } else {
            result = AgentLogin.Result(status: status, detail: AgentLogin.detail(from: tail.last, status: status))
        }
        let report = onFinish
        onFinish = nil
        report?(result)
    }

    private func makePipe() -> (read: Int32, write: Int32)? {
        var fds: [Int32] = [-1, -1]
        guard Darwin.pipe(&fds) == 0 else { return nil }
        for fd in fds { _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    private final class StreamReader: @unchecked Sendable {
        private let source: DispatchSourceRead
        private let fd: Int32
        private let onData: @Sendable (Data) -> Void
        private var chunk = [UInt8](repeating: 0, count: 1 << 16)
        private var done = false
        private var resumed = false

        init(fd: Int32, queue: DispatchQueue,
             onData: @escaping @Sendable (Data) -> Void,
             onEnd: @escaping @Sendable () -> Void) {
            self.fd = fd
            self.onData = onData
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in readAvailable() }
            source.setCancelHandler {
                Darwin.close(fd)
                onEnd()
            }
        }

        func resume() {
            resumed = true
            source.resume()
        }

        func abandon() {
            if !resumed { source.resume() }
            source.cancel()
        }

        func cancel() {
            guard !done else { return }
            done = true
            source.cancel()
        }

        private func readAvailable() {
            for _ in 0..<16 where !done {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count > 0 {
                    onData(Data(chunk[0..<count]))
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                } else {
                    cancel()
                    return
                }
            }
        }
    }
}

/// Keeps the sign-in transcript and opens the first allowlisted URL once.
private nonisolated final class LoginTranscript: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var opened = false
    private let open: @Sendable (URL) -> Void
    private let cap = 256 * 1024

    init(open: @escaping @Sendable (URL) -> Void) { self.open = open }

    func feed(_ chunk: Data) { consume(chunk, flushed: false) }

    func flush() { consume(Data(), flushed: true) }

    private func consume(_ chunk: Data, flushed: Bool) {
        let found: URL? = {
            lock.lock()
            defer { lock.unlock() }
            if !chunk.isEmpty, data.count < cap {
                data.append(chunk.prefix(cap - data.count))
            }
            guard !opened else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            guard let url = AgentLogin.url(in: text, requireTerminator: !flushed) else { return nil }
            opened = true
            return url
        }()
        if let found { open(found) }
    }
}

/// Last non-empty line of a sign-in transcript, for the failure message.
private nonisolated final class LoginTail: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func feed(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        text = String((text + String(decoding: data, as: UTF8.self)).suffix(2000))
    }

    /// The last line a person can read. Authorize URLs are not the error.
    /// A terminal writes CRLF, and Swift treats that pair as one character, so
    /// splitting on a line feed alone would keep the whole transcript as one line.
    var last: String {
        lock.lock()
        defer { lock.unlock() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { continue }
            if trimmed.contains("Paste code here") { continue }
            return trimmed
        }
        return ""
    }
}

private nonisolated enum PTY {
    struct Ends { var master: Int32; var slave: Int32 }

    static func open() -> Ends? {
        let master = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC)
        guard master >= 0 else { return nil }
        guard grantpt(master) == 0, unlockpt(master) == 0, let name = ptsname(master) else {
            Darwin.close(master)
            return nil
        }
        let slaveName = String(cString: name)
        let slave = Darwin.open(slaveName, O_RDWR | O_NOCTTY)
        guard slave >= 0 else {
            Darwin.close(master)
            return nil
        }
        let flags = fcntl(slave, F_GETFD)
        if flags >= 0 { _ = fcntl(slave, F_SETFD, flags | FD_CLOEXEC) }
        return Ends(master: master, slave: slave)
    }
}
