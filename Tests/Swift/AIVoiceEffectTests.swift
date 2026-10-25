import XCTest
@testable import Fusion

/// Independent public VOiCES speech, not the model author's enhanced-speech proxy.
/// Read English + generated background is not a claim about LOL commentary quality.
final class AIVoiceEffectTests: XCTestCase {
    private func speech() throws -> [Float] {
        let directory=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"Fixtures",withExtension:nil))
        let bytes=[UInt8](try Data(contentsOf:directory.appendingPathComponent("voices-source.wav")))
        func u16(_ p:Int)->UInt16{UInt16(bytes[p])|UInt16(bytes[p+1])<<8}
        func u32(_ p:Int)->Int{Int(bytes[p])|Int(bytes[p+1])<<8|Int(bytes[p+2])<<16|Int(bytes[p+3])<<24}
        XCTAssertEqual(String(bytes:bytes.prefix(4),encoding:.ascii),"RIFF")
        var pos=12,result=[Float](),valid=false
        while pos+8<=bytes.count {
            let name=String(bytes:bytes[pos..<pos+4],encoding:.ascii),size=u32(pos+4),start=pos+8
            guard size>=0,start+size<=bytes.count else{throw FusionError("VOiCES fixture is truncated")}
            if name=="fmt " {XCTAssertEqual(u16(start),1);XCTAssertEqual(u16(start+2),1);XCTAssertEqual(u32(start+4),16000);XCTAssertEqual(u16(start+14),16);valid=true}
            if name=="data" {for i in stride(from:start,to:start+size-1,by:2){result.append(Float(Int16(bitPattern:u16(i)))/32768)};break}
            pos=start+size+(size&1)
        }
        XCTAssertTrue(valid);XCTAssertGreaterThan(result.count,16000)
        let scale=0.08/rms(result)
        return result.map{Float(Double($0)*scale)}
    }
    private func rms(_ samples:[Float])->Double{sqrt(samples.reduce(0){$0+Double($1)*Double($1)}/Double(max(1,samples.count)))}
    private func db(_ x:Double)->Double{20*log10(max(1e-10,abs(x)))}
    private func background(_ count:Int)->[Float] {
        var state:UInt64=20261025
        var signal=(0..<count).map { i -> Float in
            state=state &* 6364136223846793005 &+ 1442695040888963407
            let noise=Double(state>>11)/9007199254740992.0*2-1,t=Double(i)/16000
            return Float(0.13*sin(2*Double.pi*110*t)+0.11*sin(2*Double.pi*733*t)+0.07*sin(2*Double.pi*(190*t+90*t*t))+0.04*noise)
        }
        let scale=0.08/rms(signal)
        for i in signal.indices{signal[i]=Float(Double(signal[i])*scale)}
        return signal
    }
    private func process(_ original:[Float]) throws -> ([Float],Double,String) {
        var output=original;let count=output.count,start=Date.timeIntervalSinceReferenceDate
        let status=output.withUnsafeMutableBufferPointer { p -> Int32 in var channels=[p.baseAddress];return fusion_ai_pcm(&channels,count,16000,1,1) }
        XCTAssertEqual(status,1,VoiceSegment.aiDetail);XCTAssertTrue(output.allSatisfy{$0.isFinite})
        return(output,(Date.timeIntervalSinceReferenceDate-start)/(Double(count)/16000),VoiceSegment.aiDetail)
    }
    private func wav(_ samples:[Float])->Data {
        var data=Data();func ascii(_ x:String){data.append(contentsOf:x.utf8)}
        func u16(_ value:UInt16){var x=value.littleEndian;withUnsafeBytes(of:&x){data.append(contentsOf:$0)}}
        func u32(_ value:UInt32){var x=value.littleEndian;withUnsafeBytes(of:&x){data.append(contentsOf:$0)}}
        ascii("RIFF");u32(UInt32(36+samples.count*2));ascii("WAVEfmt ");u32(16);u16(1);u16(1);u32(16000);u32(32000);u16(2);u16(16);ascii("data");u32(UInt32(samples.count*2))
        for value in samples{u16(UInt16(bitPattern:Int16(max(-32768,min(32767,Int((value*32768).rounded()))))))}
        return data
    }
    func testIndependentSpeechSuppressionAndMixedProjectionAreMeasured() throws {
        guard VoiceSegment.aiEnabled else{throw XCTSkip("AI-edition model/effect test; ordinary package contains no runtime/model")}
        XCTAssertTrue(VoiceSegment.initializeAI(),VoiceSegment.aiDetail)
        let voice=try speech(),back=background(voice.count),mixed=zip(voice,back).map{$0+$1}
        let (solo,soloRTF,_)=try process(voice), (remainder,mixedRTF,status)=try process(mixed)
        let reduction=db(rms(solo)/rms(voice))
        XCTAssertLessThan(reduction,-3,"Actual independent speech must be attenuated, not merely renamed filter output")
        var ss=0.0,bb=0.0,sb=0.0,sy=0.0,by=0.0
        for i in voice.indices {let s=Double(voice[i]),b=Double(back[i]),y=Double(remainder[i]);ss+=s*s;bb+=b*b;sb+=s*b;sy+=s*y;by+=b*y}
        let det=ss*bb-sb*sb,gs=(sy*bb-by*sb)/det,gb=(by*ss-sy*sb)/det
        let report:[String:Any]=["sample":"PyTorch official VOiCES, SRI/Lab41, CC BY4.0","warning":"English read speech plus generated background, not LOL; projections/RMS are not perceptual quality or phone heat guarantees","seconds":Double(voice.count)/16000,"speech_remaining_rms_db":reduction,"mixed_speech_projection_db":db(gs),"mixed_background_projection_db":db(gb),"speech_RTF":soloRTF,"mixed_RTF":mixedRTF,"status":status]
        let json=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);print("FUSION_IOS_AI_EFFECT "+String(decoding:json,as:UTF8.self))
        let directory=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("ai-voice-effects")
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try json.write(to:directory.appendingPathComponent("effects.json"))
        for (name,samples) in [("mixed-input",mixed),("mixed-model-residual",remainder),("speech-input",voice),("speech-model-residual",solo)]{try wav(samples).write(to:directory.appendingPathComponent(name+".wav"))}
    }
}
