"""Check a device IPA against the local tracked build inputs without extracting it."""
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import subprocess
import sys
import zipfile

project = Path(__file__).resolve().parents[1]
ipa = Path(sys.argv[1]).resolve()
ai = "--ai" in sys.argv[2:]
def source(relative):
    return subprocess.check_output(["git", "-c", f"safe.directory={project.as_posix()}", "show", f"HEAD:{relative}"], cwd=project)
settings = source("project.yml").decode("utf-8")
version = re.search(r'MARKETING_VERSION: "([^"]+)"', settings)[1]
build = re.search(r'CURRENT_PROJECT_VERSION: "([^"]+)"', settings)[1]
if ai:
    ai_settings = source("scripts/make-ai-project.rb").decode("utf-8")
    version = re.search(r'MARKETING_VERSION[^\n]*?([0-9]+\.[0-9]+\.[0-9]+)', ai_settings)[1]
    build = re.search(r'CURRENT_PROJECT_VERSION[^\n]*?([0-9]+)', ai_settings)[1]
with zipfile.ZipFile(ipa) as package:
    assert package.testzip() is None, "ZIP integrity failure"
    names = package.namelist()
    assert len(names) == len(set(names)), "Duplicate archive entries"
    assert not any(".." in Path(n).parts or n.startswith("/") for n in names)
    prefix = "Payload/Fusion.app/"
    info = plistlib.loads(package.read(prefix + "Info.plist"))
    assert info["CFBundleShortVersionString"] == version
    assert info["CFBundleVersion"] == build
    assert info["CFBundleIdentifier"] == ("com.bilifusion.ios.ai" if ai else "com.bilifusion.ios")
    model_path = prefix + "AIAssets/gtcrn_simple.onnx"
    if ai:
        assert hashlib.sha256(package.read(model_path)).hexdigest() == "b4718df6228e7bdf1a8a435cf98f838636eb2fd331acabf86ba87c5192ebcb87"
        assert package.read(prefix + "AIAssets/GTCRN-LICENSE")
    else:
        assert model_path not in names, "AI assets leaked into normal edition"
    assert info["MinimumOSVersion"] == "16.0"
    assert sorted(info["UIDeviceFamily"]) == [1, 2]
    assert "UIApplicationSceneManifest" in info
    executable = package.read(prefix + info["CFBundleExecutable"])
    magic, cpu, _, _, commands, _, _, _ = struct.unpack_from("<8I", executable)
    assert magic == 0xFEEDFACF and cpu == 0x0100000C, "Not arm64 Mach-O"
    offset = 32
    platforms = []
    for _ in range(commands):
        command, size = struct.unpack_from("<II", executable, offset)
        assert size >= 8 and offset + size <= len(executable)
        if command == 0x32:
            platforms.append(struct.unpack_from("<I", executable, offset + 8)[0])
        offset += size
    assert platforms == [2], "Not an iOS device executable (simulator is platform 7)"
    assert not any(".xctest/" in n or "/Fixtures/" in n for n in names), "Test assets leaked into IPA"
    tracked = subprocess.check_output(["git", "-c", f"safe.directory={project.as_posix()}", "ls-tree", "-r", "--name-only", "HEAD", "Fusion/Web"], cwd=project).decode("utf-8")
    resources = sorted(p.removeprefix("Fusion/Web/") for p in tracked.splitlines())
    packaged = sorted(n[len(prefix + "Web/"):] for n in names if n.startswith(prefix + "Web/") and not n.endswith("/"))
    assert resources == packaged, "Web resource list mismatch"
    for relative in resources:
        assert package.read(prefix + "Web/" + relative) == source("Fusion/Web/" + relative), relative
print(json.dumps({"version": version, "build": build, "edition": "AI" if ai else "normal", "architecture": "arm64", "platform": "iOS device",
                  "minimumOS": info["MinimumOSVersion"], "deviceFamilies": info["UIDeviceFamily"],
                  "webFilesVerified": len(resources), "size": ipa.stat().st_size,
                  "sha256": hashlib.sha256(ipa.read_bytes()).hexdigest().upper()}, indent=2))
