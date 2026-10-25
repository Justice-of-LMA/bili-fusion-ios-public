"""Require the requested iPad runtime; never silently fall back to 18.x."""
import json
import re
import sys
import os

major = int(os.environ.get("FUSION_TEST_IOS_MAJOR", "26"))

with open(sys.argv[1], encoding="utf-8") as source:
    devices = json.load(source)["devices"]
candidates = []
for runtime, entries in devices.items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match or int(match[1]) != major:
        continue
    for device in entries:
        if device.get("isAvailable") and "iPad" in device["name"]:
            candidates.append((int(match[2]), "Pro" in device["name"], runtime, device))
if not candidates:
    sys.exit(f"No installed iPadOS {major}.x simulator. Refusing an unrelated runtime.")
_, _, runtime, device = sorted(candidates, key=lambda item: item[:2], reverse=True)[0]
print(runtime + " / " + device["name"], file=sys.stderr)
print(device["udid"])
