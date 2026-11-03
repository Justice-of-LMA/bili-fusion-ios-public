import XCTest
import WebKit
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

    @MainActor func testPlaybackChoosesActualQualityAcrossHlsFormats() throws {
        func codec(_ quality: Int, _ urls: [JSON]) -> JSON {
            ["codec_name":"avc", "base_url":"/index.m3u8", "current_qn":quality,
             "accept_qn":[80,150,10000], "url_info":urls]
        }
        let low = codec(80, [["host":"https://low.bilivideo.com", "extra":""]])
        let high = codec(10000, [["host":"https://evil.test", "extra":""],
                                ["host":"https://another.invalid", "extra":""],
                                ["host":"http://high.bilivideo.com", "extra":"?fixture=1"]])
        let play: JSON = ["playurl_info":["playurl":["stream":[["format":[
            ["format_name":"ts", "codec":[low]], ["format_name":"fmp4", "codec":[high]]
        ]]]]]]
        let automatic = try BiliAPI.playback(play, requested:0)
        XCTAssertEqual(automatic.int("currentQuality"),10000)
        XCTAssertEqual(automatic.arr("sources").first?.str("url"),"https://high.bilivideo.com/index.m3u8?fixture=1")
        let limited = try BiliAPI.playback(play, requested:150)
        XCTAssertEqual(limited.int("currentQuality"),80)
        XCTAssertEqual(limited.int("requestedQuality"),150)
    }

    @MainActor func testResolvePreparesIdentityOnceAndUsesCurrentLoginCookies() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        defer { withExtendedLifetime(dataStore) {} }
        let store = dataStore.httpCookieStore
        func setSession(_ value: String) async throws {
            let cookie = try XCTUnwrap(HTTPCookie(properties:[.name:"SESSDATA", .value:value,
                .domain:".bilibili.com", .path:"/", .secure:"TRUE"]))
            await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in store.setCookie(cookie) { c.resume() } }
        }
        try await setSession("fixture-first")
        var requests = [URLRequest]()
        let api = BiliAPI(cookieStore:store) { request in
            requests.append(request)
            let url = try XCTUnwrap(request.url)
            let data: JSON
            if url.path.hasSuffix("/spi") {
                try await Task.sleep(nanoseconds:20_000_000)
                data = ["b_3":"fixture-buvid-three", "b_4":"fixture-buvid-four"]
            } else if url.path.hasSuffix("/get_info") {
                data = ["room_id":6, "live_status":1, "title":"fixture"]
            } else {
                XCTAssertEqual(url.path,"/xlive/web-room/v2/index/getRoomPlayInfo")
                let codec:JSON = ["codec_name":"avc", "base_url":"/index.m3u8", "current_qn":80,
                    "accept_qn":[80], "url_info":[["host":"https://fixture.bilivideo.com", "extra":""]]]
                data = ["playurl_info":["playurl":["stream":[["format":[["format_name":"ts", "codec":[codec]]]]]]]]
            }
            return (try JSONSerialization.data(withJSONObject:["code":0,"data":data]),
                    HTTPURLResponse(url:url,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        async let video = api.resolve("6",quality:0)
        async let audio = api.resolve("6",quality:0,audioOnly:true)
        _ = try await (video,audio)
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/spi") == true }.count,1)
        let play = requests.filter { $0.url?.path.hasSuffix("/getRoomPlayInfo") == true }
        XCTAssertEqual(play.count,2)
        let quality = Set(play.compactMap { URLComponents(url:$0.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="qn"})?.value })
        XCTAssertEqual(quality,Set(["80","10000"]))
        for request in play {
            let header = request.value(forHTTPHeaderField:"Cookie") ?? ""
            XCTAssertTrue(header.contains("SESSDATA=fixture-first"))
            XCTAssertTrue(header.contains("buvid3=fixture-buvid-three"))
            XCTAssertTrue(header.contains("buvid4=fixture-buvid-four"))
            XCTAssertEqual(request.value(forHTTPHeaderField:"User-Agent"),PlatformRoom.desktopUA)
        }
        try await setSession("fixture-second")
        _ = try await api.resolve("6",quality:150)
        XCTAssertEqual(requests.filter { $0.url?.path.hasSuffix("/spi") == true }.count,1)
        let last = try XCTUnwrap(requests.last)
        XCTAssertTrue((last.value(forHTTPHeaderField:"Cookie") ?? "").contains("SESSDATA=fixture-second"))
        XCTAssertFalse((last.value(forHTTPHeaderField:"Cookie") ?? "").contains("fixture-first"))
        XCTAssertEqual(URLComponents(url:last.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="qn"})?.value,"150")
    }
}
