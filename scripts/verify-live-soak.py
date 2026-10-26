"""Read-only checks of actual native live-room telemetry, not fixture or API probes."""
import argparse
import hashlib
import json
from pathlib import Path


def verify(path, ai):
    raw = path.read_bytes()
    report = json.loads(raw)
    def require(condition, reason):
        if not condition:
            raise ValueError(reason)
    require(report.get("inputRooms") == {"A": "7777", "B": "6"}, "Wrong public live room pairing")
    require(report.get("aiEdition") is ai, "Wrong live-test edition")
    require(report.get("authenticated") is True, "Bilibili login was not verified in the actual iOS simulator")
    require(report.get("completed") is True, "Actual five-minute run did not finish")
    require(report.get("actualSeconds", 0) >= 300, "Less than five minutes of real native playback")
    samples = report.get("samples", [])
    require(len(samples) >= 290, "Incomplete one-second native-player telemetry")
    require(report.get("bAudioOnlyAfterSeconds") == 150, "Missing B audio-only transition")
    require(any(s.get("bAudioOnly") for s in samples), "B audio-only mode was not exercised")
    ops = report.get("operations", [])
    require(sum(o.get("op") == "resolve" for o in ops) == 2, "Unexpected automatic stream resolution")
    require(sum(o.get("op") == "mediaOpen" for o in ops) == 2, "Player/item was reopened during live soak")
    require(not any(o.get("op") == "mediaSeek" for o in ops), "A seek may have hidden stalled playback")
    for source in ["A", "B"]:
        require(report.get("progressSeconds", {}).get(source, 0) > 270, source + " playback did not advance")
        require(report.get("longestNoProgressSeconds", {}).get(source, 300) < 5, source + " sustained stall")
        require(report.get("newVideoFramesSampled", {}).get(source, 0) > (30 if source == "A" else 15), source + " decoded frames missing")
        require(all(not s.get(source, {}).get("error") for s in samples), source + " reports a playback error")
    return {"file": path.name, "sha256": hashlib.sha256(raw).hexdigest().upper(),
            "edition": "AI" if ai else "normal", "actualSeconds": report["actualSeconds"],
            "sampleCount": len(samples), "progressSeconds": report["progressSeconds"],
            "longestNoProgressSeconds": report["longestNoProgressSeconds"],
            "newVideoFramesSampled": report["newVideoFramesSampled"],
            "limitation": "Cloud iPad simulator; not physical-device/network certification"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("report", type=Path)
    parser.add_argument("--ai", action="store_true")
    args = parser.parse_args()
    print(json.dumps(verify(args.report, args.ai), indent=2))
