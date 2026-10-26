import XCTest
@testable import Fusion

final class MediaFetchTraceTests:XCTestCase{
    func testRecordsUnchangedPlaylistAndActualRequestWaitWithoutAnyNewRequest(){
        var trace=MediaFetchTrace();let one=Data("#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:10\n#EXTINF:3,\none.ts\n".utf8)
        let first=trace.begin(now:0);trace.finish(first,now:0.2,status:200,isManifest:true,body:one,age:4)
        let second=trace.begin(now:3)
        XCTAssertEqual(trace.snapshot(now:8)["oldestPendingSeconds"] as? Double,5)
        trace.finish(second,now:10.2,status:200,isManifest:true,body:one,age:10)
        let result=trace.snapshot(now:11)
        XCTAssertEqual(result.int("requests"),2);XCTAssertEqual(result.int("pending"),0)
        XCTAssertEqual(result.int("samePlaylistResponses"),1);XCTAssertEqual(result["longestUnchangedPlaylistSeconds"] as? Double,10)
        XCTAssertEqual((result["lastManifestRequestSeconds"] as? Double) ?? -1,7.2,accuracy:0.0001)
        XCTAssertEqual(result["lastMediaSequence"] as? Int64,10)
        XCTAssertEqual(result["largestResponseAgeSeconds"] as? Double,10)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject:result))
        XCTAssertFalse(String(describing:result).contains("one.ts"));XCTAssertFalse(String(describing:result).contains("http"))
    }
    func testFailedRequestIsCountedOnceAndNeverAutomaticallyRetried(){
        var trace=MediaFetchTrace();let id=trace.begin(now:1)
        trace.finish(id,now:4,status:0,isManifest:false,body:Data())
        trace.finish(id,now:8,status:200,isManifest:true,body:Data("secret".utf8))
        let result=trace.snapshot(now:10)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject:result))
        XCTAssertEqual(result.int("requests"),1);XCTAssertEqual(result.int("failures"),1)
        XCTAssertEqual(result.int("manifestResponses"),0);XCTAssertEqual(result.int("pending"),0)
    }
}
