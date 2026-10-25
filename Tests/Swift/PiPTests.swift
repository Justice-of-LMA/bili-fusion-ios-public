import XCTest
import AVKit
@testable import Fusion

final class PiPTests: XCTestCase {
    private func chat(_ text: String) -> JSON { ["cmd":"DANMU_MSG","info":[[],text,[1,"测试观众"]]] }
    func testMessageListUsesMediaClockAndHonoursSCDeletion() {
        var store = PiPMessageStore()
        store.receive(chat("比音频提前到达的消息"),edge:20)
        XCTAssertTrue(store.visible(time:10,edge:20,rows:5,chat:true,sc:true).isEmpty)
        XCTAssertEqual(store.visible(time:20,edge:20,rows:5,chat:true,sc:true).count,1)
        let sc: JSON = ["cmd":"SUPER_CHAT_MESSAGE","data":["id":12,"message":"合成醒目留言","price":30,"time":60,"user_info":["uname":"SC 测试"]]]
        store.receive(sc,edge:21,now:100)
        store.receive(sc,edge:21,now:100)
        XCTAssertEqual(store.visible(time:22,edge:22,rows:5,chat:true,sc:true).count,2)
        XCTAssertEqual(store.visible(time:22,edge:22,rows:5,chat:false,sc:true).count,1)
        store.receive(["cmd":"SUPER_CHAT_MESSAGE_DELETE","data":["ids":[12]]],edge:22)
        XCTAssertEqual(store.visible(time:22,edge:22,rows:5,chat:true,sc:true).count,1)
        store.clearMessages(); XCTAssertTrue(store.items.isEmpty)
    }
    func testUPEmotesAreImagesAndUnsafeImageURLsStayText() {
        var store = PiPMessageStore()
        store.learn(["emoji":"[UP表情_加油]","url":"https://i0.hdslb.com/bfs/live/fixture.png","width":80,"height":40])
        store.learn(["emoji":"[坏链接]","url":"https://hdslb.com.evil.test/a.png"])
        store.receive(chat("加油[UP表情_加油][坏链接]"),edge:10)
        let parts = store.items[0].parts
        XCTAssertEqual(parts.count,3); guard parts.count == 3 else { return }; XCTAssertNotNil(parts[1].image); XCTAssertEqual(parts[1].ratio,2)
        XCTAssertNil(parts[2].image); XCTAssertEqual(parts[2].text,"[坏链接]")
        var meta = [Any](repeating:0,count:16); meta[13] = ["url":"https://i0.hdslb.com/bfs/live/direct.png"]
        store.receive(["cmd":"DANMU_MSG","info":[meta,"[专属表情]",[1,"主播粉丝"]]],edge:10)
        XCTAssertEqual(store.items.last?.parts.count,1); XCTAssertNotNil(store.items.last?.parts.first?.image)
    }
    func testBareEmojiAliasesNeverReplaceOrdinaryText() {
        var store = PiPMessageStore()
        for word in ["第一", "生气", "加油", "笑"] {
            store.learn(["emoji":"[2233娘_"+word+"]", "alt":word, "text":word, "aliases":[word], "url":"https://i0.hdslb.com/emoji.png"])
        }
        let ordinary = "第一名生气了，给他加油笑一笑"
        store.receive(chat(ordinary), edge:1)
        XCTAssertEqual(store.items[0].parts, [PiPFragment(text:ordinary)])
        store.receive(chat("[2233娘_第一]"), edge:2)
        XCTAssertNotNil(store.items[1].parts[0].image)
        var meta = [Any](repeating:0,count:16)
        meta[13] = ["url":"https://i0.hdslb.com/direct.png"]
        store.receive(["cmd":"DANMU_MSG","info":[meta,"第一",[1,"观众"]]],edge:3)
        XCTAssertNotNil(store.items.last?.parts.first?.image)
        XCTAssertEqual(store.items.last?.text,"第一")
    }
    func testBarePlatformNamesOnlyMatchBracketedTags() {
        var store=PiPMessageStore()
        for name in ["阴险","惊讶","花","妙","微笑","欢喜","第一"] {
            store.learn(["emoji":name,"url":"https://i0.hdslb.com/fixture.png"])
        }
        store.receive(chat("童站表情来咯[阴险][惊讶][花][妙][微笑][欢喜]"),edge:1)
        XCTAssertEqual(store.items[0].parts.filter { $0.image != nil }.count,6)
        store.receive(chat("第一名微笑着加油[没收录]"),edge:2)
        XCTAssertEqual(store.items[1].parts,[PiPFragment(text:"第一名微笑着加油[没收录]")])
    }
    func testRowsAreBoundedAndPauseClearsRatherThanFreezes() {
        var store = PiPMessageStore()
        for i in 0..<500 { store.receive(chat("消息 \(i)"),edge:10) }
        XCTAssertLessThanOrEqual(store.items.count,180)
        XCTAssertEqual(store.visible(time:11,edge:11,rows:5,chat:true,sc:false).map(\.text),["消息 495","消息 496","消息 497","消息 498","消息 499"])
        store.clearMessages(); XCTAssertTrue(store.visible(time:11,edge:11,rows:5,chat:true,sc:true).isEmpty)
        store.receive(chat("恢复后的新消息"),edge:nil)
        XCTAssertTrue(store.visible(time:10,edge:12,rows:5,chat:true,sc:true).isEmpty)
        XCTAssertEqual(store.visible(time:12,edge:12,rows:5,chat:true,sc:true).count,1)
    }
    @MainActor func testNativeListFrameAndSampleBuffer() throws {
        var store = PiPMessageStore()
        for text in ["比赛声音与二路解说分别控制", "这波配合很精彩 😄", "只显示二路，不读取其他 App 画面"] { store.receive(chat(text),edge:0) }
        store.receive(["cmd":"SUPER_CHAT_MESSAGE","data":["id":1,"message":"这是合成 SC，未发送真实付费留言","price":30,"time":60,"user_info":["uname":"测试观众"]]],edge:0)
        let frame = MessagePictureInPicture.draw(store.visible(time:1,edge:1,rows:5,chat:true,sc:true),title:"二路消息 · 测试房间",status:"弹幕 / SC 已连接",paused:false)
        XCTAssertEqual(frame.size,CGSize(width:960,height:640))
        let sample = try XCTUnwrap(MessagePictureInPicture.sample(frame))
        XCTAssertTrue(CMSampleBufferIsValid(sample)); XCTAssertTrue(CMSampleBufferDataIsReady(sample))
        let url = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("pip-list-qa.png")
        try frame.pngData()?.write(to:url)
        let modes = Bundle.main.object(forInfoDictionaryKey:"UIBackgroundModes") as? [String]
        XCTAssertEqual(modes,["audio"])
        let manager = MessagePictureInPicture(); XCTAssertFalse(manager.enabled); XCTAssertFalse(manager.active)
    }
    @MainActor func testSystemPiPStartsWhenSimulatorSupportsIt() async throws {
        let manager = MessagePictureInPicture()
        guard manager.supported else { throw XCTSkip("Simulator does not support PiP; device transition still needs real iPad verification") }
        let delegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let view = try XCTUnwrap(delegate.window?.rootViewController?.view)
        manager.clock = { (20,20,false,true) }
        manager.selectRoom("6",title:"画中画系统启动测试")
        manager.receive(["packet":chat("本地合成测试，不连接直播网络")])
        defer { manager.stop() }
        try manager.start(in:view)
        for _ in 0..<90 {
            if manager.active { break }
            if !manager.enabled { break }
            try await Task.sleep(nanoseconds:200_000_000)
        }
        XCTAssertTrue(manager.active,"System PiP did not activate; do not claim a verified system transition")
        XCTAssertGreaterThan(manager.renderedFrames,0)
        manager.setPaused(true); XCTAssertEqual(manager.modelCount,0)
    }
}
