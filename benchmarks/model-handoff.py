#!/usr/bin/env python3
"""Build and run the headless tree-first volume hand-off regression test.

The test uses a one-node in-memory scan fixture and temporary directory names;
it never opens the GUI or invokes agent discovery. The copied Model.swift gets
deterministic old/new volume delays and values so a stale result can be tested.
"""
import argparse
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output", type=pathlib.Path, default=ROOT / "build/model-handoff")
parser.add_argument("--measure", action="store_true", help="measure tree visibility with a delayed volume snapshot")
parser.add_argument("--ref", help="use this Git revision's app/Model.swift as the comparison source")
parser.add_argument("--runs", type=int, default=1, help="run the compiled harness this many times")
args = parser.parse_args()
if args.runs < 1:
    parser.error("--runs must be positive")

work = pathlib.Path(tempfile.mkdtemp(prefix="blitztree-model-handoff-"))
try:
    model = (subprocess.check_output(["git", "show", f"{args.ref}:app/Model.swift"], cwd=ROOT).decode()
             if args.ref else (ROOT / "app/Model.swift").read_text())
    marker = "    static func read(_ path: String) -> VolumeSpace {\n"
    if args.measure:
        injection = (
            marker
            + "        let fixture = URL(fileURLWithPath: path).lastPathComponent\n"
            + "        if fixture == \"latency\" {\n"
            + "            Thread.sleep(forTimeInterval: 1.5)\n"
            + "            return VolumeSpace(free: 777, used: 888)\n"
            + "        }\n"
        )
    else:
        injection = (
            marker
            + "        let fixture = URL(fileURLWithPath: path).lastPathComponent\n"
            + "        if fixture == \"old\" {\n"
            + "            Thread.sleep(forTimeInterval: 0.35)\n"
            + "            return VolumeSpace(free: 111, used: 333)\n"
            + "        }\n"
            + "        if fixture == \"new\" {\n"
            + "            Thread.sleep(forTimeInterval: 0.05)\n"
            + "            return VolumeSpace(free: 222, used: 444)\n"
            + "        }\n"
        )
    if model.count(marker) != 1:
        raise SystemExit("VolumeSpace.read shape changed; update the test injection")
    (work / "Model.swift").write_text(model.replace(marker, injection, 1))

    sources = [
        work / "Model.swift",
        ROOT / "app/Agent.swift",
        ROOT / "app/Cleanup.swift",
        ROOT / "benchmarks/ModelHandoff.swift",
    ]
    fixture_object = work / "model_fixture.o"
    subprocess.run(
        ["clang", "-O2", "-mmacosx-version-min=14.0", "-c",
         str(ROOT / "benchmarks/model_fixture.c"), "-o", str(fixture_object)],
        check=True,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["swiftc", *(str(path) for path in sources), str(fixture_object),
         "-import-objc-header", str(ROOT / "app/bz.h"),
         "-O", "-parse-as-library", "-swift-version", "6",
         "-default-isolation", "MainActor", "-target", "arm64-apple-macos14.0",
         "-Xcc", "-include", "-Xcc", "removefile.h",
         "-framework", "AppKit", "-framework", "SwiftUI", "-o", str(args.output.resolve())],
        check=True,
    )
    mode = ["--measure"] if args.measure else []
    for _ in range(args.runs):
        subprocess.run([str(args.output.resolve()), *mode], check=True)
finally:
    shutil.rmtree(work)
