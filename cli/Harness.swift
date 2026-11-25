import Darwin
import Foundation

/// A failure whose only payload is the sentence shown to the caller.
struct Note: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

/// Agent-facing command groups for BlitzTree. The scan, the Clean Up
/// candidates and the CSV writer stay in the `blitztree` engine. This
/// process only parses arguments, starts that executable, and prints its
/// JSON (or a short table of the same object).
nonisolated enum Harness {
    static let tool = "cli-anything-blitztree"
    static let defaultTimeout: TimeInterval = 21_600
    static let maxTimeout: TimeInterval = 86_400
    /// One quick-wins report is at most 1 000 paths. 32 MiB leaves room for
    /// long paths and fails closed if the engine writes more than that.
    static let captureCap = 32 << 20

    struct GlobalOptions: Sendable {
        var json = false
        var sessionPath: String?
        var timeout: TimeInterval = Harness.defaultTimeout
        var jsonExplicit = false
        var sessionExplicit = false
        var timeoutExplicit = false
        var help = false
        var version = false
    }

    enum Plan: Sendable, Equatable {
        case help
        case version
        case repl
        case noop
        case sessionStatus
        case sessionClear
        /// `argv` is the engine's argument vector, without the executable.
        case engine(argv: [String])
        case reject(code: Int32, message: String)
    }

    struct Prepared: Sendable {
        var program: String
        var options: GlobalOptions
        var plan: Plan
    }

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        Darwin.exit(run(CommandLine.arguments))
    }

    static func run(_ args: [String]) -> Int32 {
        let prepared = prepare(args)
        return execute(prepared)
    }

    // MARK: Parsing

    static func prepare(_ args: [String]) -> Prepared {
        let program = URL(fileURLWithPath: args.first ?? tool).lastPathComponent
        var options = GlobalOptions()
        var positionals: [String] = []
        var values: [String: String] = [:]
        var expect: String?
        var failure: String?

        func take(_ flag: String, _ value: String) {
            if values[flag] != nil {
                failure = "Duplicate option: \(flag)"
                return
            }
            values[flag] = value
        }

        var index = 1
        while index < args.count && failure == nil {
            let token = args[index]
            if let flag = expect {
                if token.isEmpty {
                    failure = "\(flag) cannot be empty"
                } else if token.hasPrefix("-") {
                    failure = "\(flag) cannot take an option as its value: \(token)"
                } else {
                    take(flag, token)
                }
                expect = nil
                index += 1
                continue
            }
            switch token {
            case "--json":
                if options.jsonExplicit { failure = "Duplicate option: --json" }
                options.json = true
                options.jsonExplicit = true
            case "--help", "-h":
                options.help = true
            case "--version":
                options.version = true
            case "--session", "--timeout", "--root", "--min-bytes", "--limit", "--output":
                expect = token
            default:
                if token.hasPrefix("-") { failure = "Unknown option: \(token)" }
                else { positionals.append(token) }
            }
            index += 1
        }
        if failure == nil, let flag = expect { failure = "Missing value for \(flag)" }

        if let failure {
            return Prepared(program: program, options: options, plan: .reject(code: 2, message: failure))
        }
        if options.help || positionals.first == "help" {
            return Prepared(program: program, options: options, plan: .help)
        }
        if options.version {
            return Prepared(program: program, options: options, plan: .version)
        }
        if let timeout = values["--timeout"] {
            guard let seconds = TimeInterval(timeout), seconds >= 1, seconds <= maxTimeout,
                  asciiDigits(timeout) else {
                return Prepared(program: program, options: options,
                                plan: .reject(code: 2, message: "--timeout must be a whole number of seconds from 1 to 86400"))
            }
            options.timeout = seconds
            options.timeoutExplicit = true
        }
        if let session = values["--session"] {
            options.sessionPath = session
            options.sessionExplicit = true
        }

        let plan = planCommand(positionals, values: values)
        return Prepared(program: program, options: options, plan: plan)
    }

    /// One REPL line. Globals set at startup stay in force unless the line sets them.
    static func prepareLine(_ line: String, base: GlobalOptions) -> Prepared {
        switch split(line) {
        case .failure(let failure):
            return Prepared(program: tool, options: base, plan: .reject(code: 2, message: failure.description))
        case .success(let parts):
            if parts.isEmpty {
                return Prepared(program: tool, options: base, plan: .noop)
            }
            var prepared = prepare([tool] + parts)
            if !prepared.options.sessionExplicit { prepared.options.sessionPath = base.sessionPath }
            if !prepared.options.jsonExplicit { prepared.options.json = base.json }
            if !prepared.options.timeoutExplicit { prepared.options.timeout = base.timeout }
            return prepared
        }
    }

    static func split(_ line: String) -> Result<[String], Note> {
        var args: [String] = []
        var current = ""
        var quote: Character?
        var escaping = false
        var started = false
        for character in line {
            if escaping {
                current.append(character)
                escaping = false
                started = true
                continue
            }
            if character == "\\", quote != "'" {
                escaping = true
                started = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
                else { current.append(character) }
                started = true
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                started = true
                continue
            }
            if character.isWhitespace {
                if started {
                    args.append(current)
                    current = ""
                    started = false
                }
                continue
            }
            current.append(character)
            started = true
        }
        if escaping || quote != nil { return .failure(Note("Unclosed quote")) }
        if started { args.append(current) }
        return .success(args)
    }

    private static func planCommand(_ positionals: [String], values: [String: String]) -> Plan {
        let group = positionals.first
        let rest = group == nil ? [] : Array(positionals.dropFirst())
        switch group {
        case nil:
            return rejectFlags(values, allowed: []) ?? .repl
        case "repl":
            return rejectFlags(values, allowed: []) ?? (rest.isEmpty ? .repl : .reject(code: 2, message: "Unexpected argument: \(rest[0])"))
        case "status":
            return rejectFlags(values, allowed: []) ?? (rest.isEmpty ? .sessionStatus : .reject(code: 2, message: "Unexpected argument: \(rest[0])"))
        case "session":
            if let extra = rest.dropFirst().first {
                return .reject(code: 2, message: "Unexpected argument: \(extra)")
            }
            if let rejected = rejectFlags(values, allowed: []) { return rejected }
            switch rest.first {
            case "status": return .sessionStatus
            case "clear": return .sessionClear
            default:
                return .reject(code: 2, message: "session needs a subcommand: status or clear")
            }
        case "scan":
            return enginePlan(command: "scan", subcommand: nil, rest: rest, values: values,
                              allowed: ["--root", "--min-bytes", "--limit"])
        case "cleanup":
            guard rest.first == "list" else {
                return .reject(code: 2, message: "cleanup needs a subcommand: list")
            }
            return enginePlan(command: "quick-wins", subcommand: "list", rest: Array(rest.dropFirst()), values: values,
                              allowed: ["--root", "--min-bytes", "--limit"])
        default:
            return .reject(code: 2, message: "Unknown command: \(group ?? ""). Use --help.")
        }
    }

    private static func enginePlan(command: String, subcommand: String?, rest: [String], values: [String: String],
                                   allowed: [String]) -> Plan {
        if let extra = rest.first {
            return .reject(code: 2, message: "Unexpected argument: \(extra)")
        }
        let label = [subcommand == nil ? command : nil, subcommand].compactMap { $0 }.joined(separator: " ")
        let shown = command == "quick-wins" ? "cleanup list" : label
        if let rejected = rejectFlags(values, allowed: allowed, command: shown) { return rejected }
        if let limit = values["--limit"] {
            guard let number = Int(limit), (1...1000).contains(number), asciiDigits(limit) else {
                return .reject(code: 2, message: "--limit must be an integer between 1 and 1000")
            }
        }
        if let minBytes = values["--min-bytes"], !asciiDigits(minBytes) {
            return .reject(code: 2, message: "--min-bytes must be an unsigned integer")
        }
        var argv = [command]
        for flag in ["--root", "--min-bytes", "--limit"] where allowed.contains(flag) {
            if let value = values[flag] { argv.append(contentsOf: [flag, value]) }
        }
        return .engine(argv: argv)
    }

    private static func rejectFlags(_ values: [String: String], allowed: [String], command: String? = nil) -> Plan? {
        let globals: Set<String> = ["--timeout", "--session"]
        for flag in values.keys.sorted() where !allowed.contains(flag) && !globals.contains(flag) {
            if let command {
                return .reject(code: 2, message: "\(flag) is not valid with \(command)")
            }
            return .reject(code: 2, message: "\(flag) is not valid here")
        }
        return nil
    }

    /// ASCII `0`...`9` only, matching the engine's integer parser.
    private static func asciiDigits(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (48...57).contains($0) }
    }

    // MARK: Running

    static func execute(_ prepared: Prepared) -> Int32 {
        switch prepared.plan {
        case .noop:
            return 0
        case .help:
            return emit(text: helpText(prepared.program), json: helpObject(prepared.program), options: prepared.options, code: 0)
        case .version:
            return emit(text: "\(tool)\nengine contract: blitztree schema_version 1\n",
                        json: versionObject(), options: prepared.options, code: 0)
        case .repl:
            return repl(prepared.options)
        case .sessionStatus:
            return sessionStatus(prepared.options)
        case .sessionClear:
            return sessionClear(prepared.options)
        case .engine(let argv):
            return runEngine(argv, options: prepared.options)
        case .reject(let code, let message):
            return fail(code, message, options: prepared.options)
        }
    }

    private static func repl(_ options: GlobalOptions) -> Int32 {
        FileHandle.standardError.write(Data("""
        \(tool)
        Drives the BlitzTree scan engine. scan and cleanup list only read metadata.
        help lists commands. exit leaves.

        """.utf8))
        var last: Int32 = 0
        while let line = readLine(strippingNewline: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "exit" || trimmed == "quit" { return 0 }
            let prepared = prepareLine(line, base: options)
            if case .noop = prepared.plan { continue }
            last = execute(prepared)
            if case .repl = prepared.plan { return last }
        }
        return last
    }

    private static func runEngine(_ argv: [String], options: GlobalOptions) -> Int32 {
        switch resolveEngine() {
        case .failure(let failure):
            return fail(1, failure.description, options: options)
        case .success(let executable):
            let outcome = Subprocess.runBlocking(
                Subprocess.Spec(executable, argv, input: .none),
                stdout: .capture(cap: captureCap),
                stderr: .capture(cap: captureCap),
                timeout: options.timeout)
            if !outcome.stderr.isEmpty {
                FileHandle.standardError.write(outcome.stderr)
            }
            if !outcome.started {
                return fail(1, outcome.launchError ?? "Could not start \(executable)", options: options)
            }
            if outcome.timedOut {
                return fail(1, "The blitztree engine exceeded the \(Int(options.timeout)) second limit.", options: options)
            }
            if outcome.overflow || outcome.leaked {
                return fail(1, "The blitztree engine wrote more than \(captureCap) bytes; the report was discarded.", options: options)
            }
            if outcome.signaled {
                return fail(1, "The blitztree engine stopped on signal \(outcome.status).", options: options)
            }
            let stdout = outcome.stdout
            if options.json {
                var bytes = stdout
                if bytes.last != 0x0A { bytes.append(0x0A) }
                if !writeStdout(bytes) { return 1 }
            } else if let object = jsonObject(stdout) {
                let rendered = render(object)
                if !writeStdout(Data(rendered.utf8)) { return 1 }
            } else {
                FileHandle.standardError.write(Data("The blitztree engine did not write a JSON object.\n".utf8))
                if !writeStdout(stdout) { return 1 }
            }
            if outcome.status == 0, let object = jsonObject(stdout) {
                remember(object, options: options)
            }
            return outcome.status
        }
    }

    static func resolveEngine() -> Result<String, Note> {
        if let given = ProcessInfo.processInfo.environment["BLITZTREE_BIN"] {
            if given.isEmpty { return .failure(Note("BLITZTREE_BIN is empty.")) }
            if !isExecutableFile(given) {
                return .failure(Note("BLITZTREE_BIN is not an executable file: \(given)"))
            }
            return .success(given)
        }
        // `blitztree-engine`, not `blitztree`. On a case-insensitive volume the
        // latter is the GUI executable `BlitzTree`. PATH still searches for `blitztree`.
        if let beside = executableDirectory().map({ $0 + "/blitztree-engine" }), isExecutableFile(beside) {
            return .success(beside)
        }
        if let found = searchPath("blitztree") { return .success(found) }
        return .failure(Note("""
        The blitztree engine was not found beside \(tool) or on an absolute PATH entry.
        Build it from the BlitzTree repository:
          cargo install --locked --path . --features cli --bin blitztree
        Or set BLITZTREE_BIN to that executable. ./build.sh also places it next to this program inside BlitzTree.app.
        """))
    }

    /// Directory of this process. `_NSGetExecutablePath` is the path that was executed, which is where `./build.sh` installs the engine.
    static func executableDirectory() -> String? {
        var size = UInt32(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: Int(size))
        if _NSGetExecutablePath(&buffer, &size) != 0 {
            buffer = [CChar](repeating: 0, count: Int(size))
            guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    static func isExecutableFile(_ path: String) -> Bool {
        var directory: ObjCBool = false
        let files = FileManager.default
        return files.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue
            && files.isExecutableFile(atPath: path)
    }

    /// Absolute PATH entries only. A relative entry, including `.`, is ignored so a planted `./blitztree` cannot win.
    static func searchPath(_ name: String) -> String? {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") where directory.hasPrefix("/") {
            let candidate = "\(directory)/\(name)"
            if isExecutableFile(candidate) { return candidate }
        }
        return nil
    }

    // MARK: Session

    static func defaultSessionPath() -> String? {
        guard let home = ProcessInfo.processInfo.environment["HOME"], !home.isEmpty, home.hasPrefix("/") else {
            return nil
        }
        return URL(fileURLWithPath: home).appendingPathComponent(".blitztree/cli-anything-session.json").path
    }

    private static func sessionPath(_ options: GlobalOptions) -> Result<String, Note> {
        if let path = options.sessionPath { return .success(path) }
        if let path = defaultSessionPath() { return .success(path) }
        return .failure(Note("HOME is not an absolute directory, and no --session file was given."))
    }

    private static func sessionStatus(_ options: GlobalOptions) -> Int32 {
        switch sessionPath(options) {
        case .failure(let failure):
            return fail(2, failure.description, options: options)
        case .success(let path):
            switch SessionFile.load(path) {
            case .failure(let failure):
                return fail(1, failure.description, options: options)
            case .success(let session):
                let text = session.map { render($0) } ?? "No session at \(path)\n"
                let object: [String: Any] = [
                    "schema_version": 1, "tool": tool, "command": "session status",
                    "session_path": path, "session": session as Any,
                ]
                return emit(text: text, json: object, options: options, code: 0)
            }
        }
    }

    private static func sessionClear(_ options: GlobalOptions) -> Int32 {
        switch sessionPath(options) {
        case .failure(let failure):
            return fail(2, failure.description, options: options)
        case .success(let path):
            switch SessionFile.clear(path) {
            case .failure(let failure):
                return fail(1, failure.description, options: options)
            case .success:
                let object: [String: Any] = [
                    "schema_version": 1, "tool": tool, "command": "session clear", "session_path": path, "cleared": true,
                ]
                return emit(text: "Cleared \(path)\n", json: object, options: options, code: 0)
            }
        }
    }

    private static func remember(_ report: [String: Any], options: GlobalOptions) {
        guard let root = report["root"] as? String else { return }
        switch sessionPath(options) {
        case .failure:
            return
        case .success(let path):
            var session: [String: Any] = ["schema_version": 1, "root": root]
            if let command = report["command"] { session["command"] = command }
            if let readOnly = report["read_only"] { session["read_only"] = readOnly }
            if let generated = report["generated_at_unix"] { session["generated_at_unix"] = generated }
            if let message = SessionFile.store(path, session) {
                FileHandle.standardError.write(Data("Could not record the session at \(path): \(message)\n".utf8))
            }
        }
    }

    // MARK: Output

    static func helpText(_ program: String) -> String {
        """
        \(program) — agent CLI for BlitzTree

        Drives the blitztree scan engine. It does not delete files.
        scan and cleanup list are read-only.

        Usage:
          \(program) [--json] [--session FILE] [--timeout SECONDS] <command>

        Commands:
          scan [--root PATH] [--min-bytes N] [--limit N]
          cleanup list [--root PATH] [--min-bytes N] [--limit N]
          status
          session status
          session clear
          repl
          help

        No command starts the REPL. --json prints the engine's stdout, and adds a newline only when it omitted one.
        Default root is your home. Default min-bytes is 50000000. Default limit is 20 (max 1000).
        Default timeout is 21600 seconds (max 86400).
        A session file records the last successful root. Default: ~/.blitztree/cli-anything-session.json
        The session file and its directory must be real files, not symlinks.
        A value that starts with - is rejected. --limit, --min-bytes and --timeout accept only ASCII digits.

        The engine is BLITZTREE_BIN when that is set. Otherwise it is blitztree-engine beside this program, then an absolute PATH entry named blitztree. A relative PATH entry is ignored.
          cargo install --locked --path . --features cli --bin blitztree

        """
    }

    private static func helpObject(_ program: String) -> [String: Any] {
        [
            "schema_version": 1, "tool": tool, "program": program,
            "help": helpText(program),
            "commands": ["scan", "cleanup list", "status", "session status", "session clear", "repl"],
        ]
    }

    private static func versionObject() -> [String: Any] {
        [
            "schema_version": 1, "tool": tool,
            "engine_contract": "blitztree schema_version 1",
        ]
    }

    static func render(_ object: [String: Any]) -> String {
        if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
            return message + "\n"
        }
        var lines: [String] = []
        if let root = object["root"] as? String { lines.append("root: \(root)") }
        if let summary = object["summary"] as? [String: Any] {
            lines.append("allocated \(number(summary["allocated_bytes"]))  logical \(number(summary["logical_bytes"]))  files \(number(summary["file_count"]))  directories \(number(summary["directory_count"]))")
        }
        if let coverage = object["coverage"] as? [String: Any] {
            lines.append("complete: \(coverage["complete"] as? Bool == true ? "true" : "false")")
        }
        if let report = object["report"] as? [String: Any] {
            if let output = report["output"] as? String {
                lines.append("output: \(output)")
                lines.append("rows: \(number(report["rows"]))  bytes_written: \(number(report["bytes_written"]))")
            }
            if let candidates = report["candidates"] as? [[String: Any]] {
                lines.append(table(["path", "allocated_bytes", "category", "group", "verify"], rows: candidates.map {
                    [string($0["path"]), number($0["allocated_bytes"]), string($0["category"]), string($0["group"]), string($0["verify"])]
                }))
            }
            for key in ["largest_files", "largest_directories", "largest_children"] {
                guard let rows = report[key] as? [[String: Any]] else { continue }
                lines.append(key.replacingOccurrences(of: "_", with: " ") + ":")
                lines.append(table(["path", "allocated_bytes", "kind", "complete"], rows: rows.map {
                    [string($0["path"]), number($0["allocated_bytes"]), string($0["kind"]), string($0["complete"])]
                }))
            }
        }
        if lines.isEmpty { return String(data: jsonData(object) ?? Data(), encoding: .utf8) ?? "" }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func table(_ headers: [String], rows: [[String]]) -> String {
        var lines = [headers.joined(separator: "  ")]
        lines.append(contentsOf: rows.map { $0.joined(separator: "  ") })
        return lines.joined(separator: "\n")
    }

    private static func string(_ value: Any?) -> String {
        switch value {
        case let text as String: return text
        case let number as NSNumber: return number.stringValue
        case nil: return ""
        default: return String(describing: value)
        }
    }

    private static func number(_ value: Any?) -> String { string(value) }

    private static func emit(text: String, json object: [String: Any], options: GlobalOptions, code: Int32) -> Int32 {
        if options.json {
            guard let data = jsonData(object) else {
                FileHandle.standardError.write(Data("Could not encode JSON.\n".utf8))
                return 1
            }
            return writeStdout(data) ? code : 1
        }
        return writeStdout(Data(text.utf8)) ? code : 1
    }

    private static func fail(_ code: Int32, _ message: String, options: GlobalOptions) -> Int32 {
        let object: [String: Any] = [
            "schema_version": 1, "tool": tool,
            "error": ["message": message, "exit_code": code],
        ]
        if options.json {
            guard let data = jsonData(object) else { return 1 }
            return writeStdout(data) ? code : 1
        }
        FileHandle.standardError.write(Data(message.hasSuffix("\n") ? message.utf8 : (message + "\n").utf8))
        return code
    }

    static func jsonObject(_ data: Data) -> [String: Any]? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return value
    }

    private static func jsonData(_ object: [String: Any]) -> Data? {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else {
            return nil
        }
        data.append(contentsOf: [0x0A])
        return data
    }

    @discardableResult
    private static func writeStdout(_ data: Data) -> Bool {
        do {
            try FileHandle.standardOutput.write(contentsOf: data)
            return true
        } catch {
            FileHandle.standardError.write(Data("Cannot write report: \(error)\n".utf8))
            return false
        }
    }
}

/// The last successful engine report's root, behind an exclusive lock.
/// A symlink at the session path is refused (`O_NOFOLLOW`). A symlink at the session directory is refused before it is followed.
nonisolated enum SessionFile {
    static func load(_ path: String) -> Result<[String: Any]?, Note> {
        if !FileManager.default.fileExists(atPath: path) { return .success(nil) }
        return locked(path, exclusive: false, create: false) { fd in
            let data = readAll(fd)
            if data.isEmpty { return nil }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw POSIXError(.EINVAL)
            }
            return object
        }
    }

    /// Nil on success. The parent directory is created at 0700 and the file at 0600.
    /// A symlink at the parent is refused before any chmod, which would follow it.
    static func store(_ path: String, _ object: [String: Any]) -> String? {
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if let failure = ensurePrivateDirectory(parent) { return failure }
        let encoded: Data
        do {
            encoded = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            return error.localizedDescription
        }
        let stored = locked(path, exclusive: true, create: true) { fd -> Void in
            if ftruncate(fd, 0) != 0 { throw posix() }
            if fchmod(fd, 0o600) != 0 { throw posix() }
            var bytes = [UInt8](encoded)
            bytes.append(0x0A)
            var written = 0
            while written < bytes.count {
                let count = bytes.withUnsafeBytes { raw -> Int in
                    guard let base = raw.baseAddress else { return -1 }
                    return Darwin.write(fd, base.advanced(by: written), bytes.count - written)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw posix()
                }
                written += count
            }
        }
        if case .failure(let failure) = stored { return failure.description }
        return nil
    }

    static func clear(_ path: String) -> Result<Void, Note> {
        if !FileManager.default.fileExists(atPath: path) { return .success(()) }
        return locked(path, exclusive: true, create: false) { fd in
            if ftruncate(fd, 0) != 0 { throw posix() }
            if unlink(path) != 0 { throw posix() }
        }
    }

    /// Creates `path` as a real directory at mode 0700. A symlink at `path` is refused before chmod, which would follow it.
    /// Ancestor symlinks stay as they are: `/tmp` is one, and refusing those would reject ordinary session paths.
    private static func ensurePrivateDirectory(_ path: String) -> String? {
        if let reason = symlinkAt(path) { return reason }
        if isRealDirectory(path) {
            return chmod(path, 0o700) == 0 ? nil : String(cString: strerror(errno))
        }
        let grand = URL(fileURLWithPath: path).deletingLastPathComponent().path
        if grand != path && !isRealDirectory(grand) {
            do {
                try FileManager.default.createDirectory(atPath: grand, withIntermediateDirectories: true)
            } catch {
                return error.localizedDescription
            }
        }
        if mkdir(path, 0o700) != 0 && errno != EEXIST {
            return String(cString: strerror(errno))
        }
        if let reason = symlinkAt(path) { return reason }
        guard isRealDirectory(path) else { return "\(path) is not a directory." }
        return chmod(path, 0o700) == 0 ? nil : String(cString: strerror(errno))
    }

    private static func isRealDirectory(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// A sentence when `path` is a symlink. Nil when it is missing or any other file type.
    private static func symlinkAt(_ path: String) -> String? {
        var info = stat()
        if lstat(path, &info) != 0 { return nil }
        if (info.st_mode & S_IFMT) == S_IFLNK {
            return "\(path) is a symlink; the session directory must be a real directory."
        }
        return nil
    }

    private static func locked<T>(_ path: String, exclusive: Bool, create: Bool, _ body: (Int32) throws -> T) -> Result<T, Note> {
        let flags = create ? (O_RDWR | O_CREAT | O_NOFOLLOW) : (O_RDWR | O_NOFOLLOW)
        let fd = open(path, flags, 0o600)
        if fd < 0 { return .failure(Note(String(cString: strerror(errno)))) }
        defer { close(fd) }
        while flock(fd, exclusive ? LOCK_EX : LOCK_SH) != 0 {
            if errno != EINTR { return .failure(Note(String(cString: strerror(errno)))) }
        }
        defer { flock(fd, LOCK_UN) }
        do { return .success(try body(fd)) }
        catch { return .failure(Note(error.localizedDescription)) }
    }

    private static func readAll(_ fd: Int32) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func posix() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
