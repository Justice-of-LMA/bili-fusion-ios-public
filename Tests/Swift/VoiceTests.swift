import XCTest
@testable import Fusion
final class VoiceTests:XCTestCase {
    func fixture(_ mono:Bool=false)throws->Data{var p:UnsafeMutablePointer<UInt8>?,length=0;XCTAssertEqual(fusion_voice_fixture(mono ? 1:0,&p,&length),1);let ptr=try XCTUnwrap(p);defer{fusion_voice_free(ptr)};return Data(bytes:ptr,count:length)}
    func legacy(_ data:Data,strength:Float)->(Data,Int32){var out:UnsafeMutablePointer<UInt8>?,count=0;let status=data.withUnsafeBytes{fusion_voice_segment($0.bindMemory(to:UInt8.self).baseAddress,data.count,strength,&out,&count)};guard status==1,let out else{return(data,status)};defer{fusion_voice_free(out)};return(Data(bytes:out,count:count),status)}
    func metrics(_ data:Data)->[Double]{var v=[Double](repeating:0,count:4);let status=data.withUnsafeBytes{fusion_voice_metrics($0.bindMemory(to:UInt8.self).baseAddress,data.count,&v)};XCTAssertEqual(status,1);return v}
    func testActualAACCentreAttenuationSidePreservationAndTimeline()throws{
        let original=try fixture(),before=metrics(original),result=legacy(original,strength:1)
        XCTAssertEqual(result.1,1);let after=metrics(result.0)
        XCTAssertLessThan(after[0],before[0]*0.3);XCTAssertGreaterThan(after[1],before[1]*0.8);XCTAssertLessThan(after[1],before[1]*1.2)
        XCTAssertEqual(after[2],before[2],accuracy:0.025);XCTAssertEqual(after[3],before[3],accuracy:0.025)
    }
    func testOffAndMonoBypassBitExactly()throws{for pair in [(try fixture(),Float(0)),(try fixture(true),Float(1))]{let r=legacy(pair.0,strength:pair.1);XCTAssertEqual(r.1,0);XCTAssertEqual(r.0,pair.0)}}
    func testMalformedAndBoundedInputIsNotReplacedWithBrokenMedia(){let bytes=Data(repeating:0,count:4096),r=legacy(bytes,strength:1);XCTAssertNotEqual(r.1,1);XCTAssertEqual(r.0,bytes)}
}

