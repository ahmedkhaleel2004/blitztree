import Darwin
import Foundation

/// Parser tests run in process. The built CLI is spawned for anything that
/// starts the engine, writes a session, or reads stdin.
@main
struct CLIAnythingChecks {
    static func main() {
        parsing()
        rendering()
        sessionFile()
        guard let bin = ProcessInfo.processInfo.environment["CLI_ANYTHING_BIN"], Harness.isExecutableFile(bin) else {
            fputs("CLI_ANYTHING_BIN is not an executable file\n", stderr)
            exit(1)
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-anything-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        spawned(bin, root)
        if let engine = ProcessInfo.processInfo.environment["BLITZTREE_BIN"], Harness.isExecutableFile(engine) {
            realEngine(bin, engine, root)
        } else {
            print("SKIP real blitztree engine (BLITZTREE_BIN is not an executable)")
        }
        print("CLIAnythingChecks passed")
    }

    private static func check(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL \(message)\n", stderr)
            exit(1)
        }
    }

    private static func parsing() {
        let help = Harness.prepare(["cli-anything-blitztree", "scan", "--help"])
        if case .help = help.plan {} else { check(false, "scan --help should be help") }

        let repl = Harness.prepare(["cli-anything-blitztree"])
        if case .repl = repl.plan {} else { check(false, "no command should be the REPL") }

        let status = Harness.prepare(["cli-anything-blitztree", "status"])
        if case .sessionStatus = status.plan {} else { check(false, "status") }

        func rejected(_ args: [String], _ snippet: String) {
            let prepared = Harness.prepare(["cli-anything-blitztree"] + args)
            guard case .reject(let code, let message) = prepared.plan else {
                check(false, "\(args) should be rejected, plan was \(prepared.plan)")
                return
            }
            check(code == 2, "\(args) exit \(code)")
            check(message.contains(snippet), "\(args) message \(message)")
        }
        rejected(["nope"], "Unknown command")
        rejected(["cleanup"], "cleanup needs a subcommand")
        rejected(["scan", "--output", "out.csv"], "not valid with scan")
        rejected(["scan", "--limit", "0"], "--limit must be")
        rejected(["scan", "--limit", "1001"], "--limit must be")
        rejected(["scan", "--limit", "1.5"], "--limit must be")
        rejected(["scan", "--min-bytes", "-1"], "cannot take an option")
        rejected(["scan", "--root", "--json"], "cannot take an option")
        rejected(["--session", "--json", "status"], "cannot take an option")
        rejected(["scan", "--limit", "١"], "--limit must be")
        rejected(["scan", "--min-bytes", "١"], "--min-bytes must be")
        rejected(["--timeout", "١", "scan"], "--timeout must be")
        rejected(["scan", "--root"], "Missing value")
        rejected(["scan", "--root", "/tmp", "--root", "/tmp"], "Duplicate option")
        rejected(["--json", "--json", "scan"], "Duplicate option: --json")
        rejected(["--timeout", "0", "scan"], "--timeout must be")
        rejected(["scan", "extra"], "Unexpected argument")
        rejected(["session"], "session needs a subcommand")

        let scan = Harness.prepare(["cli-anything-blitztree", "scan", "--limit", "3", "--root", "/tmp", "--min-bytes", "1", "--json"])
        guard case .engine(let argv) = scan.plan else {
            check(false, "scan plan \(scan.plan)")
            return
        }
        check(argv == ["scan", "--root", "/tmp", "--min-bytes", "1", "--limit", "3"], "argv \(argv)")
        check(scan.options.json, "json flag")

        switch Harness.split("scan --root \"/tmp/my dir\"") {
        case .success(let parts):
            check(parts == ["scan", "--root", "/tmp/my dir"], "split \(parts)")
        case .failure(let failure):
            check(false, failure.description)
        }
        if case .success = Harness.split("scan \"oops") { check(false, "unclosed quote accepted") }

        let line = Harness.prepareLine("cleanup list --root /tmp", base: scan.options)
        guard case .engine(let cleanup) = line.plan else {
            check(false, "line plan \(line.plan)")
            return
        }
        check(cleanup == ["quick-wins", "--root", "/tmp"], "cleanup argv \(cleanup)")
        check(line.options.json, "REPL keeps --json from startup")
    }

    private static func rendering() {
        let text = Harness.render([
            "root": "/tmp/project",
            "summary": ["allocated_bytes": 4096, "logical_bytes": 12, "file_count": 1, "directory_count": 1],
            "coverage": ["complete": true],
            "report": ["largest_files": [["path": "/tmp/project/a", "allocated_bytes": 4096, "kind": "file_or_link", "complete": true]]],
        ])
        check(text.contains("root: /tmp/project"), text)
        check(text.contains("/tmp/project/a"), text)
        check(text.contains("complete: true"), text)
    }

    private static func sessionFile() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-anything-session-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("session.json").path
        switch SessionFile.load(path) {
        case .success(let value): check(value == nil, "missing session should be empty")
        case .failure(let failure): check(false, failure.description)
        }
        let error = SessionFile.store(path, ["schema_version": 1, "root": "/tmp/project"])
        check(error == nil, error ?? "")
        switch SessionFile.load(path) {
        case .success(let value): check(value?["root"] as? String == "/tmp/project", "stored root")
        case .failure(let failure): check(false, failure.description)
        }
        let link = directory.appendingPathComponent("linked.json").path
        check(symlink(path, link) == 0, "symlink")
        if case .success = SessionFile.load(link) { check(false, "session load followed a symlink") }
        switch SessionFile.clear(path) {
        case .success: check(!FileManager.default.fileExists(atPath: path), "clear removes the file")
        case .failure(let failure): check(false, failure.description)
        }

        let real = directory.appendingPathComponent("real-session-dir")
        try! FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        check(chmod(real.path, 0o755) == 0, "chmod real session dir")
        let alias = directory.appendingPathComponent("alias-session-dir")
        check(symlink(real.path, alias.path) == 0, "symlink session dir")
        let through = alias.appendingPathComponent("session.json").path
        let refused = SessionFile.store(through, ["schema_version": 1, "root": "/tmp/project"])
        check(refused?.contains("symlink") == true, refused ?? "stored through a symlink directory")
        check(!FileManager.default.fileExists(atPath: real.appendingPathComponent("session.json").path), "wrote through the session directory symlink")
        var info = stat()
        check(stat(real.path, &info) == 0, "stat real session dir")
        check(info.st_mode & 0o777 == 0o755, "chmod followed the session directory symlink (\(String(info.st_mode, radix: 8)))")

        let realGrand = directory.appendingPathComponent("real-grand")
        try! FileManager.default.createDirectory(at: realGrand, withIntermediateDirectories: true)
        let linkParent = directory.appendingPathComponent("link-parent")
        check(symlink(realGrand.path, linkParent.path) == 0, "symlink ancestor")
        let underLink = linkParent.appendingPathComponent("child/session.json").path
        check(SessionFile.store(underLink, ["schema_version": 1, "root": "/tmp/under-link"]) == nil, "ancestor symlink should still hold a session")
        check(FileManager.default.fileExists(atPath: realGrand.appendingPathComponent("child/session.json").path), "session was not created through the ancestor symlink")

        let nested = directory.appendingPathComponent("fresh-parent/session.json").path
        check(SessionFile.store(nested, ["schema_version": 1, "root": "/tmp/nested"]) == nil, "create a real session directory")
        switch SessionFile.load(nested) {
        case .success(let value): check(value?["root"] as? String == "/tmp/nested", "nested root")
        case .failure(let failure): check(false, failure.description)
        }
    }

    private static func spawned(_ bin: String, _ root: URL) {
        let fake = root.appendingPathComponent("fake-engine")
        let script = """
        #!/bin/zsh
        joined="${(j: :)@}"
        if [[ "$joined" == *sleep* ]]; then
          sleep 5
          exit 0
        fi
        if [[ "$joined" == *fail* ]]; then
          printf '%s\\n' '{"schema_version":1,"error":{"message":"nope","exit_code":2}}'
          exit 2
        fi
        printf '%s\\n' '{"schema_version":1,"tool":"blitztree","command":"scan","read_only":true,"root":"/tmp/from-engine","report":{"largest_files":[{"path":"/tmp/from-engine/a","allocated_bytes":5,"kind":"file_or_link","complete":true}]}}'
        exit 0
        """
        try! script.write(to: fake, atomically: true, encoding: .utf8)
        check(chmod(fake.path, 0o755) == 0, "chmod fake")

        let session = root.appendingPathComponent("agent-session.json").path
        let home = root.appendingPathComponent("home")
        try! FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let help = run(bin, ["--help"], env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        check(help.status == 0, "help status \(help.status) \(help.stderr)")
        check(help.stdout.contains("cleanup list"), help.stdout)

        let bad = run(bin, ["--json", "nope"], env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        check(bad.status == 2, "bad status \(bad.status)")
        let badJSON = Harness.jsonObject(Data(bad.stdout.utf8))
        check(badJSON?["tool"] as? String == "cli-anything-blitztree", bad.stdout)
        check((badJSON?["error"] as? [String: Any])?["exit_code"] as? Int == 2, bad.stdout)

        let missing = run(bin, ["--json", "scan", "--root", "/tmp"], env: ["HOME": home.path, "PATH": "/usr/bin:/bin"])
        check(missing.status == 1, "missing engine status \(missing.status) \(missing.stdout)")
        check(missing.stdout.contains("cargo install"), missing.stdout)

        let pointed = run(bin, ["--json", "scan"], env: [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "BLITZTREE_BIN": root.appendingPathComponent("missing").path,
        ])
        check(pointed.status == 1, "bad BLITZTREE_BIN status")
        check(pointed.stdout.contains("BLITZTREE_BIN is not an executable"), pointed.stdout)
        check(!pointed.stdout.contains("not found on PATH"), pointed.stdout)

        let passed = run(bin, ["--json", "--session", session, "scan", "--root", "/tmp"], env: [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "BLITZTREE_BIN": fake.path,
        ])
        check(passed.status == 0, "pass-through status \(passed.status) \(passed.stderr)")
        check(passed.stdout == "{\"schema_version\":1,\"tool\":\"blitztree\",\"command\":\"scan\",\"read_only\":true,\"root\":\"/tmp/from-engine\",\"report\":{\"largest_files\":[{\"path\":\"/tmp/from-engine/a\",\"allocated_bytes\":5,\"kind\":\"file_or_link\",\"complete\":true}]}}\n",
              "stdout changed: \(passed.stdout)")
        switch SessionFile.load(session) {
        case .success(let value): check(value?["root"] as? String == "/tmp/from-engine", "session \(String(describing: value))")
        case .failure(let failure): check(false, failure.description)
        }

        let failed = run(bin, ["--json", "scan", "--root", "fail"], env: [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "BLITZTREE_BIN": fake.path,
        ])
        check(failed.status == 2, "engine exit \(failed.status)")
        check(failed.stdout.contains("\"exit_code\":2"), failed.stdout)

        let human = run(bin, ["--session", session, "scan"], env: [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "BLITZTREE_BIN": fake.path,
        ])
        check(human.status == 0, "human status")
        check(human.stdout.contains("/tmp/from-engine/a"), human.stdout)
        check(!human.stdout.hasPrefix("{"), "human output should not be the raw object")

        let slow = run(bin, ["--json", "--timeout", "1", "scan", "--root", "sleep"], env: [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "BLITZTREE_BIN": fake.path,
        ])
        check(slow.status == 1, "timeout status \(slow.status) \(slow.stdout) \(slow.stderr)")
        check(slow.stdout.contains("exceeded"), slow.stdout)

        let repl = run(bin, ["--session", session], env: [
            "HOME": home.path, "PATH": "/usr/bin:/bin", "BLITZTREE_BIN": fake.path,
        ], stdin: "status\nexit\n")
        check(repl.status == 0, "repl status \(repl.status) \(repl.stderr)")
        check(repl.stdout.contains("/tmp/from-engine"), repl.stdout)

        let cleared = run(bin, ["--json", "--session", session, "session", "clear"], env: [
            "HOME": home.path, "PATH": "/usr/bin:/bin",
        ])
        check(cleared.status == 0, "clear \(cleared.stderr)")
        check(!FileManager.default.fileExists(atPath: session), "session file remains")

        func engineScript(_ path: URL, _ marker: String) {
            let body = """
            #!/bin/zsh
            printf '%s\\n' '{"schema_version":1,"tool":"blitztree","command":"scan","read_only":true,"root":"\(marker)","report":{}}'
            exit 0
            """
            try! body.write(to: path, atomically: true, encoding: .utf8)
            check(chmod(path.path, 0o755) == 0, "chmod \(path.path)")
        }
        let trapDir = root.appendingPathComponent("trap")
        try! FileManager.default.createDirectory(at: trapDir, withIntermediateDirectories: true)
        engineScript(trapDir.appendingPathComponent("blitztree"), "/trap")
        let relative = run(bin, ["--json", "scan", "--root", "/tmp"], env: [
            "HOME": home.path, "PATH": "trap",
        ], directory: root.path)
        check(relative.status == 1, "relative PATH status \(relative.status) \(relative.stdout)")
        check(relative.stdout.contains("cargo install"), relative.stdout)
        check(!relative.stdout.contains("/trap"), "relative PATH was searched: \(relative.stdout)")

        let absDir = root.appendingPathComponent("abs-engine")
        try! FileManager.default.createDirectory(at: absDir, withIntermediateDirectories: true)
        engineScript(absDir.appendingPathComponent("blitztree"), "/from-path")
        let absolute = run(bin, ["--json", "scan", "--root", "/tmp"], env: [
            "HOME": home.path, "PATH": "\(absDir.path):/usr/bin:/bin",
        ])
        check(absolute.status == 0, "absolute PATH \(absolute.status) \(absolute.stdout)")
        check(absolute.stdout.contains("\"root\":\"/from-path\""), absolute.stdout)

        let beside = URL(fileURLWithPath: bin).deletingLastPathComponent().appendingPathComponent("blitztree-engine")
        engineScript(beside, "/beside")
        let sibling = run(bin, ["--json", "scan", "--root", "/tmp"], env: [
            "HOME": home.path, "PATH": "\(absDir.path):/usr/bin:/bin",
        ])
        check(sibling.status == 0, "sibling status \(sibling.status) \(sibling.stdout)")
        check(sibling.stdout.contains("\"root\":\"/beside\""), sibling.stdout)
        check(!sibling.stdout.contains("/from-path"), "PATH won over the engine beside the program: \(sibling.stdout)")
    }

    private static func realEngine(_ bin: String, _ engine: String, _ root: URL) {
        let home = root.appendingPathComponent("real-home")
        let project = home.appendingPathComponent("proj")
        let modules = project.appendingPathComponent("node_modules/pkg")
        try! FileManager.default.createDirectory(at: modules, withIntermediateDirectories: true)
        try! Data("{}\n".utf8).write(to: project.appendingPathComponent("package.json"))
        try! Data(repeating: 0x78, count: 8192).write(to: modules.appendingPathComponent("lib.js"))
        let session = root.appendingPathComponent("real-session.json").path
        let capture = root.appendingPathComponent("engine-capture.bin")
        let argvFile = root.appendingPathComponent("engine-argv.txt")
        let wrapper = root.appendingPathComponent("engine-wrapper")
        let wrapperScript = """
        #!/bin/zsh
        printf '%s\\n' "$@" > "$BLITZTREE_ARGV"
        "$BLITZTREE_REAL" "$@" > "$BLITZTREE_CAPTURE"
        engine_status=$?
        cat "$BLITZTREE_CAPTURE"
        exit $engine_status
        """
        try! wrapperScript.write(to: wrapper, atomically: true, encoding: .utf8)
        check(chmod(wrapper.path, 0o755) == 0, "chmod wrapper")
        let env = ["HOME": home.path, "PATH": "/usr/bin:/bin", "BLITZTREE_BIN": engine]
        var scanEnv = env
        scanEnv["BLITZTREE_BIN"] = wrapper.path
        scanEnv["BLITZTREE_REAL"] = engine
        scanEnv["BLITZTREE_CAPTURE"] = capture.path
        scanEnv["BLITZTREE_ARGV"] = argvFile.path

        let scan = run(bin, ["--json", "--session", session, "scan", "--root", home.path, "--min-bytes", "1", "--limit", "20"], env: scanEnv)
        check(scan.status == 0, "real scan \(scan.status) \(scan.stderr) \(scan.stdout)")
        let captured = (try? String(contentsOf: capture, encoding: .utf8)) ?? ""
        check(scan.stdout == captured, "stdout is not the engine's bytes")
        let argvText = (try? String(contentsOf: argvFile, encoding: .utf8)) ?? ""
        check(argvText == "scan\n--root\n\(home.path)\n--min-bytes\n1\n--limit\n20\n", "engine argv \(argvText)")
        let scanJSON = Harness.jsonObject(Data(scan.stdout.utf8))
        check(scanJSON?["schema_version"] as? Int == 1, scan.stdout)
        check(scanJSON?["command"] as? String == "scan", scan.stdout)
        check(scanJSON?["read_only"] as? Bool == true, scan.stdout)
        let resolvedHome = canonical(home.path)
        check(scanJSON?["root"] as? String == resolvedHome, "root \(scanJSON?["root"] ?? "nil") expected \(resolvedHome)")
        check(scan.stdout.contains("lib.js"), "scan did not name the file: \(scan.stdout)")
        print("scan: \(home.path)")

        let cleanup = run(bin, ["--json", "cleanup", "list", "--root", home.path, "--min-bytes", "1", "--limit", "20"], env: env)
        check(cleanup.status == 0, "real cleanup \(cleanup.status) \(cleanup.stderr)")
        check(cleanup.stdout.contains("node_modules"), "cleanup missed node_modules: \(cleanup.stdout)")
        let cleanupJSON = Harness.jsonObject(Data(cleanup.stdout.utf8))
        check(cleanupJSON?["command"] as? String == "quick-wins", cleanup.stdout)
        let candidates = (cleanupJSON?["report"] as? [String: Any])?["candidates"] as? [[String: Any]] ?? []
        check(candidates.contains { $0["category"] as? String == "node_modules" }, "no node_modules candidate")
    }

    private static func canonical(_ path: String) -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(path, &buffer) != nil else { return path }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private struct Output {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    private static func run(_ bin: String, _ args: [String], env: [String: String], stdin: String = "", directory: String? = nil) -> Output {
        let outcome = Subprocess.runBlocking(
            Subprocess.Spec(bin, args, environment: env, directory: directory, input: stdin.isEmpty ? .none : .data(Data(stdin.utf8))),
            stdout: .capture(cap: 8 << 20),
            stderr: .capture(cap: 1 << 20),
            timeout: 60)
        return Output(status: outcome.status, stdout: outcome.output, stderr: String(decoding: outcome.stderr, as: UTF8.self))
    }
}
