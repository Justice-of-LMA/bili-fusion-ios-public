# AI assets (separate edition only)

Model: `gtcrn_simple.onnx`, 535190 bytes. SHA256 `b4718df6228e7bdf1a8a435cf98f838636eb2fd331acabf86ba87c5192ebcb87`.

Author source (MIT): https://github.com/Xiaobin-Rong/gtcrn/tree/502ebfab64da7c4a9af78dcb9c6ceef1ebb01c73 . The model is a streaming speech-enhancement network; this app subtracts its sample-aligned estimated speech, rather than playing its enhanced-speech output. This is not a guarantee of studio vocal separation or retaining all game sounds.

Official ONNX Runtime iOS binary 1.24.2 is pinned by Microsoft's own SPM manifest:
https://github.com/microsoft/onnxruntime-swift-package-manager/blob/357ec527490789b8637bc12e3b671fdc3dd14263/Package.swift
https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.24.2.zip
SHA256 `f7100a992d2a8135168c8afd831e6a58b465349101982aa58b3e11d36e600b54`.
ORT source (MIT): https://github.com/microsoft/onnxruntime/tree/058787ceead760166e3c50a0a4cba8a833a6f53f . Preserve the ORT archive LICENSE in the corresponding-source distribution. ORT telemetry is explicitly disabled, CPU-only one-thread inference; audio is never sent to an AI server.

`scripts/prepare-ai-voice.sh` verifies both checksums and creates a separate project-ai.yml. Neither the model nor ONNX Runtime is included in the ordinary project. The AI project processes mono/stereo TS/AAC HLS on A only; B is unaffected. FLV/fMP4 remain unprocessed and explicitly reported. Each independently prefetched segment has its own recurrent states and a 256 ms reflected warm-up, avoiding out-of-order state contamination and reducing cold-start leakage at boundaries. This is not claimed seamless studio-quality boundary separation. Whole segments are decoded then processed offline on a worker queue, preserving sample count/rate/channel layout and video packet timestamps. This is not zero-latency streaming, and phone heat/performance still needs hardware validation.
