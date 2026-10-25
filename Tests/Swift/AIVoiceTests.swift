import XCTest
@testable import Fusion

final class AIVoiceTests: XCTestCase {
    private func enabled() throws {
        guard VoiceSegment.aiEnabled else { throw XCTSkip("Dedicated AI edition only; normal IPA must not contain a model/runtime") }
        XCTAssertTrue(VoiceSegment.initializeAI(),VoiceSegment.aiDetail)
    }
    private func samples(_ count:Int,rate:Int=16000)->[Float] {
        (0..<count).map { i in
            let t=Double(i)/Double(rate)
            return Float(0.2*sin(2*Double.pi*193*t)+0.07*sin(2*Double.pi*1733*t)*(0.5+0.5*sin(2*Double.pi*3*t)))
        }
    }
    func testOrdinaryBuildDoesNotRequireModelResources() {
        if Bundle.main.bundleIdentifier == "com.bilifusion.ios.ai" { XCTAssertTrue(VoiceSegment.aiEnabled,"AI binary must link real inference, not compile inert normal stubs") }
        if !VoiceSegment.aiEnabled {
            XCTAssertNil(Bundle.main.url(forResource:"gtcrn_simple",withExtension:"onnx",subdirectory:"AIAssets"))
        }
    }
    func testFFTOverlapAddIsSampleAlignedAndFinite() throws {
        try enabled()
        var input=samples(4097),output=[Float](repeating:0,count:4097)
        let count=input.count
        XCTAssertEqual(fusion_ai_reconstruct(&input,count,&output),1)
        let error=zip(input,output).map { abs($0-$1) }.max() ?? 1
        XCTAssertLessThan(error,0.00002,"Speech estimate must align before subtraction; no delayed voice cancellation")
    }
    func testActualModelRunsMonoStereoAtOriginalRatesAndOffIsBitExact() throws {
        try enabled()
        for rate in [16000,44100,48000] {
            let original=samples(rate/2,rate:rate)
            var left=original,right=original.map{$0*0.7},originalCopy=original
            let count=left.count
            let status=left.withUnsafeMutableBufferPointer { l in right.withUnsafeMutableBufferPointer { r in
                var planes=[l.baseAddress,r.baseAddress]
                return fusion_ai_pcm(&planes,count,Int32(rate),2,1)
            }}
            XCTAssertEqual(status,1,VoiceSegment.aiDetail);XCTAssertEqual(left.count,count);XCTAssertTrue(left.allSatisfy{$0.isFinite&&abs($0)<=1})
            XCTAssertGreaterThan(zip(original,left).map{abs($0-$1)}.reduce(0,+),0.001,"Test actual model output, not an unchanged placeholder")
            let off=originalCopy.withUnsafeMutableBufferPointer { p -> Int32 in var planes=[p.baseAddress];return fusion_ai_pcm(&planes,count,Int32(rate),1,0) }
            XCTAssertEqual(off,0);XCTAssertEqual(originalCopy,original)
        }
        XCTAssertTrue(VoiceSegment.aiDetail.contains("GTCRN local CPU"))
    }
    func testIndependentSegmentsHaveRepeatableWarmupAndBoundedFailure() throws {
        try enabled()
        let original=samples(8000)
        func run()->[Float]{var x=original;let count=x.count;x.withUnsafeMutableBufferPointer{p in var c=[p.baseAddress];XCTAssertEqual(fusion_ai_pcm(&c,count,16000,1,1),1)};return x}
        let first=run(),second=run()
        XCTAssertEqual(first,second,"Independent prefetched HLS requests cannot share out-of-order recurrent state")
        var x=original;let count=x.count
        let bad=x.withUnsafeMutableBufferPointer{p -> Int32 in var c=[p.baseAddress];return fusion_ai_pcm(&c,count,1,1,1)}
        XCTAssertLessThan(bad,0);XCTAssertEqual(x,original)
    }
    func testActualAACModelPathPreservesTimestampsAndBypassesOff() throws {
        try enabled()
        var raw:UnsafeMutablePointer<UInt8>?,length=0
        XCTAssertEqual(fusion_voice_fixture(0,&raw,&length),1)
        let ptr=try XCTUnwrap(raw);let data=Data(bytes:ptr,count:length);fusion_voice_free(ptr)
        func metrics(_ value:Data)->[Double]{var v=[Double](repeating:0,count:4);let status=value.withUnsafeBytes{fusion_voice_metrics($0.bindMemory(to:UInt8.self).baseAddress,value.count,&v)};XCTAssertEqual(status,1);return v}
        let before=metrics(data)
        let result=VoiceSegment.process(data,strength:1)
        XCTAssertEqual(result.1,1,VoiceSegment.aiDetail)
        let after=metrics(result.0)
        XCTAssertEqual(after[2],before[2],accuracy:0.025);XCTAssertEqual(after[3],before[3],accuracy:0.025)
        let off=VoiceSegment.process(data,strength:0);XCTAssertEqual(off.0,data);XCTAssertEqual(off.1,0)
        raw=nil;length=0;XCTAssertEqual(fusion_voice_fixture(1,&raw,&length),1);let monoPtr=try XCTUnwrap(raw);let monoData=Data(bytes:monoPtr,count:length);fusion_voice_free(monoPtr)
        let mono=VoiceSegment.process(monoData,strength:1);XCTAssertEqual(mono.1,1,"Model edition also supports mono AAC")
        XCTAssertEqual(VoiceSegment.process(Data(repeating:0,count:64),strength:1).0,Data(repeating:0,count:64))
    }
}
