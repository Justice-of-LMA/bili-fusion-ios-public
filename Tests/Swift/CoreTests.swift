import XCTest
@testable import Fusion

final class CoreTests: XCTestCase {
    func testRoomValidation() throws {
        XCTAssertEqual(try Safety.room("https://live.bilibili.com/7777?broadcast_type=0"), 7777)
        XCTAssertEqual(try Safety.room("6"), 6)
        for invalid in ["0", "https://live.bilibili.com.evil.test/6", "https://evil@live.bilibili.com/6", "http://live.bilibili.com/6", "9999999999999999"] { XCTAssertThrowsError(try Safety.room(invalid)) }
    }
    func testMediaWhitelist() {
        XCTAssertTrue(Safety.media(URL(string:"https://x.bilivideo.com/live/index.m3u8")!))
        for value in ["http://x.bilivideo.com/a", "https://bilivideo.com.evil.test/a", "https://127.0.0.1/a", "https://user@x.bilivideo.com/a"] { XCTAssertFalse(Safety.media(URL(string:value)!)) }
    }
    func testMessageValidation() throws {
        XCTAssertEqual(try Safety.message(" 好耶 "), "好耶")
        XCTAssertThrowsError(try Safety.message("第一行\n第二行"))
        XCTAssertThrowsError(try Safety.message(String(repeating:"好",count:41)))
    }
    func testProtocolRoundtripAndBounds() throws {
        let packet = LiveProtocol.packet(5,"{\"cmd\":\"DANMU_MSG\",\"info\":[]}")
        let values = try LiveProtocol.decode(packet)
        XCTAssertEqual(values.count,1); XCTAssertEqual(values.first?.operation,5)
        XCTAssertEqual(values.first?.data.str("cmd"),"DANMU_MSG")
        XCTAssertThrowsError(try LiveProtocol.decode(packet.dropLast()))
        XCTAssertThrowsError(try LiveProtocol.decode(Data(repeating:0,count:LiveProtocol.limit+1)))
    }
    func testWbiDeterministic() throws {
        let url="https://i0.hdslb.com/bfs/wbi/0123456789abcdef0123456789abcdef.png"
        let a=try Safety.wbi(room:7777,image:url,sub:url,seconds:100)
        XCTAssertTrue(a.matches("^id=7777&wts=100&w_rid=[a-f0-9]{32}$"))
        XCTAssertEqual(a,try Safety.wbi(room:7777,image:url,sub:url,seconds:100))
    }
    @MainActor func testOnlyHlsPlayback() throws {
        let codec: JSON = ["codec_name":"avc","base_url":"/index.m3u8","current_qn":80,"accept_qn":[80,150],"url_info":[["host":"https://x.bilivideo.com","extra":"?a=1"]]]
        let data: JSON = ["playurl_info":["playurl":["stream":[["format":[["format_name":"ts","codec":[codec]]]]]]]]
        let result=try BiliAPI.playback(data,requested:0)
        XCTAssertEqual(result.arr("sources").count,1); XCTAssertEqual(result.arr("qualities").count,2)
        XCTAssertEqual(result.arr("sources")[0].str("type"),"hls")
    }
}
