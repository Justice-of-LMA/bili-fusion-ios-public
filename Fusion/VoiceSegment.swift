import Foundation
enum VoiceSegment {
    static var aiEnabled: Bool { fusion_ai_enabled() == 1 }
    static func initializeAI() -> Bool {
        guard aiEnabled, let url=Bundle.main.url(forResource:"gtcrn_simple",withExtension:"onnx",subdirectory:"AIAssets") else { return false }
        return fusion_ai_initialize(url.path) == 1
    }
    static var aiDetail: String { String(cString:fusion_ai_detail()) }

    static func process(_ data: Data, strength: Float) -> (Data, Int32) {
        var output: UnsafeMutablePointer<UInt8>?, length = 0
        let status = data.withUnsafeBytes { bytes in
            (aiEnabled ? fusion_ai_segment : fusion_voice_segment)(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, strength, &output, &length)
        }
        guard status == 1, let output, length > 0 else { return (data, status) }
        defer { fusion_voice_free(output) }
        return (Data(bytes: output, count: length), status)
    }
}

