import Darwin
import Foundation

// The one way BlitzTree starts a child process: the agent CLIs, their
// sign-in, the installers, the cleanup commands and git. A child is spawned
// with an argument array (no shell unless the caller asks for one), its pipes
// are drained by dispatch sources (no thread parks in a read), its stdin is
// written without ever raising SIGPIPE, and every wait is bounded and
// cancellable: cancelling terminates the child, escalates to SIGKILL, and
// the result is only reported once the child has been reaped.

nonisolated enum Subprocess {
    /// What to start. `environment` replaces the whole environment; nil
    /// inherits BlitzTree's own.
    struct Spec: Sendable {
        var executable: String
        var arguments: [String]
        var environment: [String: String]?
        var directory: String?
        var input: Input
        /// Run on a pseudo-terminal (stdin, stdout and stderr all the
        /// terminal) when one can be allocated, else on pipes. The CLIs only
        /// open a browser themselves when they see a terminal.
        var terminal: Bool

        init(_ executable: String, _ arguments: [String] = [], environment: [String: String]? = nil,
             directory: String? = nil, input: Input = .none, terminal: Bool = false) {
            self.executable = executable
            self.arguments = arguments
            self.environment = environment
            self.directory = directory
            self.input = input
            self.terminal = terminal
        }
    }

    enum Input: Sendable {
        /// stdin is /dev/null.
        case none
        /// Written once, then closed (closing is what ends a stdio server).
        case data(Data)
        /// A pipe the owner feeds through `Job.write` and ends with `closeInput`.
        case open
    }

    /// Where one of the child's output streams goes.
    enum Sink: Sendable {
        /// /dev/null: nothing is read.
        case discard
        /// Keep the first `cap` bytes; `Outcome.overflow` says more came.
        case capture(cap: Int)
        /// Called in order, off the main thread, as bytes arrive.
        case stream(@Sendable (Data) -> Void)
    }

    struct Outcome: Sendable {
        /// False when the program could not be started (see `launchError`).
        var started = false
        var launchError: String?
        var pid: pid_t = 0
        /// Exit code, or the signal number when `signaled`. -1 when the child
        /// never exited (could not be started, or would not die).
        var status: Int32 = -1
        var signaled = false
        var stdout = Data()
        var stderr = Data()
        /// The time limit ran out and the child was terminated.
        var timedOut = false
        var cancelled = false
        /// Captured stdout went past its cap; only a prefix was kept.
        var overflow = false
        /// A descendant still held an output pipe when the child had exited
        /// and the drain grace ran out, so output may be incomplete.
        var leaked = false

        /// Ran to its own end: started, not cut short by the limit or by cancel.
        var finished: Bool { started && !timedOut && !cancelled }
        var output: String { String(decoding: stdout, as: UTF8.self) }
        var text: String { output.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    enum StartError: Error {
        case launch(String)
        case cancelled
    }

    /// The step a read gave: bytes, a pause, or the end of the stream. A
    /// pseudo-terminal master reports the child's exit as EIO, not as 0.
    enum ReadStep: Equatable {
        case data, wouldBlock, retry, end
    }

    static func readStep(_ count: Int, errno code: Int32) -> ReadStep {
        if count > 0 { return .data }
        if count == 0 { return .end }
        switch code {
        case EAGAIN, EWOULDBLOCK: return .wouldBlock
        case EINTR: return .retry
        default: return .end
        }
    }

    /// BlitzTree's environment with PATH replaced.
    static func environment(path: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        return environment
    }

    /// Spawns and flips descriptor flags under one lock so a child started
    /// on another thread cannot inherit a pipe end still without CLOEXEC.
    fileprivate static let spawnLock = NSLock()

    // MARK: Facades

    /// Starts, waits and returns without parking a thread: the awaiting task
    /// suspends, and cancelling it terminates the child and waits for it.
    static func run(_ spec: Spec, stdout: Sink = .capture(cap: 1 << 20), stderr: Sink = .discard,
                    timeout: TimeInterval? = nil) async -> Outcome {
        let job = Job(spec, stdout: stdout, stderr: stderr, timeout: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
                job.onFinish = { continuation.resume(returning: $0) }
                do {
                    try job.start()
                } catch {
                    continuation.resume(returning: job.failure(error))
                }
            }
        } onCancel: {
            job.cancel()
        }
    }

    /// For code that is itself synchronous (probes on a background queue).
    /// The thread waits, but never longer than the job's own bound.
    static func runBlocking(_ spec: Spec, stdout: Sink = .capture(cap: 1 << 20), stderr: Sink = .discard,
                            timeout: TimeInterval) -> Outcome {
        let job = Job(spec, stdout: stdout, stderr: stderr, timeout: timeout)
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        job.onFinish = { box.outcome = $0; done.signal() }
        do {
            try job.start()
        } catch {
            return job.failure(error)
        }
        // Job.finish is bounded by timeout + kill + drain grace; this is the
        // belt for a child the kernel will not let go of.
        let bound = max(0, timeout) + job.killGrace * 2 + job.drainGrace + 5
        if done.wait(timeout: .now() + bound) == .timedOut {
            job.terminate()
            var late = Outcome()
            late.started = true
            late.timedOut = true
            return late
        }
        return box.outcome
    }

    private final class Box: @unchecked Sendable {
        var outcome = Outcome()
    }

    // MARK: Job

    /// One running child. Everything stateful happens on the job's own serial
    /// queue; the few flags other threads touch sit behind `lock`.
    final class Job: @unchecked Sendable {
        let killGrace: TimeInterval
        let drainGrace: TimeInterval
        /// Set before `start`; called exactly once, after the child is
        /// reaped and its output drained (or given up on), unless `start` throws.
        var onFinish: (@Sendable (Outcome) -> Void)?

        private let spec: Spec
        private let timeout: TimeInterval?
        private let queue = DispatchQueue(label: "blitztree.subprocess", qos: .userInitiated)
        private let process = Process()
        private let outSink: Sink, errSink: Sink
        private let outBuffer: Capped, errBuffer: Capped

        // Behind `lock`: read from other threads.
        private let lock = NSLock()
        private var started = false
        private var pid: pid_t = 0
        private var exited = false
        private var exitStatus: Int32 = -1
        private var signaled = false
        private var cancelRequested = false
        private var terminateRequested = false

        // Only on `queue`.
        private var streams: [Reading] = []
        private var openStreams = 0
        private var inputFD: Int32 = -1
        private var writeSource: DispatchSourceWrite?
        private var pending = Data()
        private var pendingOffset = 0
        private var closeWhenDrained = false
        private var timedOut = false
        private var leaked = false
        private var finished = false
        private var timer: DispatchWorkItem?
        private var drainTimer: DispatchWorkItem?

        init(_ spec: Spec, stdout: Sink = .discard, stderr: Sink = .discard, timeout: TimeInterval? = nil,
             killGrace: TimeInterval = 1, drainGrace: TimeInterval = 2) {
            self.spec = spec
            self.timeout = timeout
            self.killGrace = killGrace
            self.drainGrace = drainGrace
            outSink = stdout
            errSink = stderr
            outBuffer = Capped(cap: Self.cap(of: stdout))
            errBuffer = Capped(cap: Self.cap(of: stderr))
        }

        private static func cap(of sink: Sink) -> Int {
            if case .capture(let cap) = sink { return cap }
            return 0
        }

        var processID: pid_t { lock.lock(); defer { lock.unlock() }; return pid }

        /// The outcome for a `start` that threw.
        func failure(_ error: Error) -> Outcome {
            var outcome = Outcome()
            switch error {
            case StartError.cancelled: outcome.cancelled = true
            case StartError.launch(let message): outcome.launchError = message
            default: outcome.launchError = error.localizedDescription
            }
            return outcome
        }

        // MARK: Starting

        func start() throws {
            lock.lock()
            precondition(!started, "a Job starts once")
            if cancelRequested { lock.unlock(); throw StartError.cancelled }
            started = true
            lock.unlock()

            var owned: [Int32] = []
            var childEnds: [Int32] = []
            func fail(_ message: String) -> StartError {
                for fd in owned + childEnds { Darwin.close(fd) }
                // The number may be handed to someone else's file at once; a
                // later write or closeInput must find nothing to act on.
                inputFD = -1
                return .launch(message)
            }

            // A terminal is the child's stdin; a separate input has nowhere to go.
            if spec.terminal {
                guard case .none = spec.input else {
                    throw StartError.launch("A terminal run takes no separate input.")
                }
            }

            Subprocess.spawnLock.lock()
            defer { Subprocess.spawnLock.unlock() }

            process.executableURL = URL(fileURLWithPath: spec.executable)
            process.arguments = spec.arguments
            if let environment = spec.environment { process.environment = environment }
            if let directory = spec.directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }

            var readFDs: [(fd: Int32, sink: Sink, buffer: Capped)] = []
            if spec.terminal, let pty = PTY.open() {
                let handle = FileHandle(fileDescriptor: pty.slave, closeOnDealloc: false)
                process.standardInput = handle
                process.standardOutput = handle
                process.standardError = handle
                childEnds.append(pty.slave)
                owned.append(pty.master)
                readFDs.append((pty.master, outSink, outBuffer))
            } else {
                switch spec.input {
                case .none:
                    process.standardInput = FileHandle.nullDevice
                case .data, .open:
                    guard let pipe = Self.makePipe() else { throw fail("Couldn't create a pipe for \(spec.executable).") }
                    process.standardInput = FileHandle(fileDescriptor: pipe.read, closeOnDealloc: false)
                    childEnds.append(pipe.read)
                    owned.append(pipe.write)
                    Self.prepareWriteEnd(pipe.write)
                    inputFD = pipe.write
                }
                for (isOut, sink, buffer) in [(true, outSink, outBuffer), (false, errSink, errBuffer)] {
                    if case .discard = sink {
                        if isOut { process.standardOutput = FileHandle.nullDevice }
                        else { process.standardError = FileHandle.nullDevice }
                        continue
                    }
                    guard let pipe = Self.makePipe() else { throw fail("Couldn't create a pipe for \(spec.executable).") }
                    let handle = FileHandle(fileDescriptor: pipe.write, closeOnDealloc: false)
                    if isOut { process.standardOutput = handle } else { process.standardError = handle }
                    childEnds.append(pipe.write)
                    owned.append(pipe.read)
                    readFDs.append((pipe.read, sink, buffer))
                }
            }

            // Readers exist (suspended) before the child can exit, so the
            // exit handler always sees the streams it has to wait for.
            for (fd, sink, buffer) in readFDs {
                let flags = fcntl(fd, F_GETFL)
                _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
                let reading = Reading(fd: fd, sink: sink, buffer: buffer, queue: queue) { [self] in streamEnded() }
                streams.append(reading)
            }
            openStreams = streams.count

            process.terminationHandler = { [self] finished in
                lock.lock()
                exited = true
                exitStatus = finished.terminationStatus
                signaled = finished.terminationReason == .uncaughtSignal
                lock.unlock()
                queue.async { [self] in handleExit() }
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                for reading in streams { reading.abandon() }
                streams = []
                openStreams = 0
                for fd in owned where !readFDs.contains(where: { $0.fd == fd }) { Darwin.close(fd) }
                for fd in childEnds { Darwin.close(fd) }
                inputFD = -1
                throw StartError.launch(error.localizedDescription)
            }
            for fd in childEnds { Darwin.close(fd) }
            lock.lock()
            pid = process.processIdentifier
            let stop = terminateRequested
            lock.unlock()
            for reading in streams { reading.resume() }
            queue.async { [self] in
                if let timeout, !finished {
                    let item = DispatchWorkItem { [self] in
                        guard !finished else { return }
                        timedOut = true
                        terminate()
                    }
                    timer = item
                    queue.asyncAfter(deadline: .now() + max(0, timeout), execute: item)
                }
                switch spec.input {
                case .data(let data): write(data); closeInput()
                case .none, .open: break
                }
            }
            if stop { terminate() }
        }

        private static func makePipe() -> (read: Int32, write: Int32)? {
            var fds: [Int32] = [-1, -1]
            guard Darwin.pipe(&fds) == 0 else { return nil }
            for fd in fds { _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC) }
            return (fds[0], fds[1])
        }

        /// Writing to a pipe whose reader is gone fails with EPIPE rather
        /// than raising SIGPIPE, whether or not the process ignores the signal.
        private static func prepareWriteEnd(_ fd: Int32) {
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC)
        }

        // MARK: Input

        /// Queues bytes for the child's stdin. Never blocks, never raises
        /// SIGPIPE: if the child is gone the bytes are dropped.
        func write(_ data: Data) {
            queue.async { [self] in
                guard inputFD >= 0, !data.isEmpty else { return }
                pending.append(data)
                pump()
            }
        }

        /// Ends stdin once everything queued has been written.
        func closeInput() {
            queue.async { [self] in
                closeWhenDrained = true
                pump()
            }
        }

        private func pump() {
            while inputFD >= 0, pendingOffset < pending.count {
                let wrote = pending.withUnsafeBytes { raw -> Int in
                    Darwin.write(inputFD, raw.baseAddress! + pendingOffset, min(raw.count - pendingOffset, 1 << 16))
                }
                if wrote > 0 {
                    pendingOffset += wrote
                } else if wrote < 0, errno == EINTR {
                    continue
                } else if wrote < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    armWriter()
                    return
                } else {
                    // EPIPE (the child closed its end or exited) or any other failure.
                    pending = Data()
                    pendingOffset = 0
                    closeInputNow()
                    return
                }
            }
            if pendingOffset >= pending.count {
                pending = Data()
                pendingOffset = 0
                if closeWhenDrained { closeInputNow() }
            }
        }

        private func armWriter() {
            guard writeSource == nil, inputFD >= 0 else { return }
            let source = DispatchSource.makeWriteSource(fileDescriptor: inputFD, queue: queue)
            source.setEventHandler { [self] in
                writeSource?.cancel()
                writeSource = nil
                pump()
            }
            writeSource = source
            source.resume()
        }

        private func closeInputNow() {
            let fd = inputFD
            inputFD = -1
            guard fd >= 0 else { return }
            if let source = writeSource {
                writeSource = nil
                source.setCancelHandler { Darwin.close(fd) }
                source.cancel()
            } else {
                Darwin.close(fd)
            }
        }

        // MARK: Stopping

        /// Task cancellation: stop the child, report `cancelled`.
        func cancel() {
            lock.lock()
            cancelRequested = true
            lock.unlock()
            terminate()
        }

        /// SIGTERM now, SIGKILL after the grace, and if even that does not
        /// end it, stop waiting. Safe to call at any time, any number of times.
        func terminate() {
            lock.lock()
            guard started, !exited else { lock.unlock(); return }
            let target = pid
            if target <= 0 { terminateRequested = true; lock.unlock(); return }
            lock.unlock()
            // Foundation starts a child as the leader of its own process
            // group, so one signal reaches its descendants too (a shell's
            // `curl`, a tool's workers). Only a group the child leads is
            // signalled, never BlitzTree's own; otherwise just the child.
            let group = getpgid(target)
            let signalsGroup = group == target && group != getpgrp() && group > 1
            func send(_ signal: Int32) {
                if signalsGroup, Darwin.kill(-group, signal) == 0 { return }
                if stillRunning { Darwin.kill(target, signal) }
            }
            send(SIGTERM)
            queue.asyncAfter(deadline: .now() + killGrace) { [self] in
                // A descendant that ignores SIGTERM can outlive the leader, so
                // the group still gets SIGKILL after the leader is gone.
                if signalsGroup { Darwin.kill(-group, SIGKILL) } else if stillRunning { Darwin.kill(target, SIGKILL) }
                queue.asyncAfter(deadline: .now() + killGrace) { [self] in
                    guard stillRunning else { return }
                    abandon()
                }
            }
        }

        private var stillRunning: Bool {
            lock.lock(); defer { lock.unlock() }
            return started && !exited && pid > 0
        }

        /// The child will not die: report it as gone rather than wait forever.
        private func abandon() {
            lock.lock()
            exited = true
            exitStatus = -1
            lock.unlock()
            handleExit()
        }

        // MARK: Finishing

        private func handleExit() {
            guard !finished, drainTimer == nil else { return }
            if openStreams == 0 { finish(); return }
            // A descendant that inherited the pipes keeps them open; give the
            // output a moment to arrive, then close our ends and move on.
            let item = DispatchWorkItem { [self] in
                guard !finished else { return }
                leaked = true
                for reading in streams { reading.cancel() }
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
            // Break the Job -> Process -> handler -> Job cycle.
            process.terminationHandler = nil
            lock.lock()
            let outcome = Outcome(
                started: true, launchError: nil, pid: pid, status: exitStatus, signaled: signaled,
                stdout: outBuffer.data, stderr: errBuffer.data, timedOut: timedOut,
                cancelled: cancelRequested, overflow: outBuffer.overflow, leaked: leaked)
            lock.unlock()
            closeInputNow()
            let report = onFinish
            onFinish = nil
            report?(outcome)
        }
    }

    // MARK: Reading

    /// One output stream, drained by a dispatch source. Ends on EOF, on EIO
    /// (what a terminal master reports), or when cancelled.
    private final class Reading: @unchecked Sendable {
        private let source: DispatchSourceRead
        private let fd: Int32
        private let sink: Sink
        private let buffer: Capped
        private var chunk = [UInt8](repeating: 0, count: 1 << 16)
        private var done = false
        private var resumed = false

        init(fd: Int32, sink: Sink, buffer: Capped, queue: DispatchQueue, ended: @escaping @Sendable () -> Void) {
            self.fd = fd
            self.sink = sink
            self.buffer = buffer
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [self] in readAvailable() }
            source.setCancelHandler {
                Darwin.close(fd)
                ended()
            }
        }

        func resume() {
            resumed = true
            source.resume()
        }

        /// For a start that failed before anything ran.
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
            // A bounded burst per event keeps one chatty child from starving
            // the others sharing the pool; the source fires again for the rest.
            for _ in 0..<16 where !done {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                switch Subprocess.readStep(count, errno: errno) {
                case .data:
                    let data = Data(chunk[0..<count])
                    switch sink {
                    case .discard: break
                    case .capture: buffer.append(data)
                    case .stream(let handler): handler(data)
                    }
                case .retry:
                    continue
                case .wouldBlock:
                    return
                case .end:
                    cancel()
                    return
                }
            }
        }
    }

    private final class Capped: @unchecked Sendable {
        private let lock = NSLock()
        private let cap: Int
        private var stored = Data()
        private var over = false
        init(cap: Int) { self.cap = cap }

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            let room = cap - stored.count
            if chunk.count > room { over = true }
            if room > 0 { stored.append(chunk.prefix(room)) }
        }

        var data: Data { lock.lock(); defer { lock.unlock() }; return stored }
        var overflow: Bool { lock.lock(); defer { lock.unlock() }; return over }
    }
}

/// A pseudo-terminal pair. A terminal makes `isatty` true, which is what the
/// CLIs check before they will open a browser themselves.
nonisolated enum PTY {
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
