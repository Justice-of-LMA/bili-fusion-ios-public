import XCTest
import JavaScriptCore
@testable import Fusion

final class SCLifetimeTests: XCTestCase {
    private func packet(_ id: Int, price: Int = 30, total: Int = 60, end: Int = 160) -> JSON {
        ["cmd":"SUPER_CHAT_MESSAGE", "data":["id":id, "price":price, "time":total,
            "start_time":end-total, "end_time":end, "message":"本地 SC 时长测试", "user_info":["uname":"测试"]]]
    }

    func testOfficialUniformAndPriceTierBoundaries() throws {
        XCTAssertEqual(SCLifetimePolicy().lifetime(price:30,officialRemaining:40,officialTotal:60)?.duration,40)
        let uniform = SCLifetimePolicy(["mode":"uniform", "uniformSeconds":120])
        XCTAssertEqual(uniform.lifetime(price:2000,officialRemaining:40,officialTotal:60)?.duration,100)
        let tiers = SCLifetimePolicy(["mode":"tiers", "tiers":["30":10,"50":20,"100":30,"500":40,"1000":50,"2000":60]])
        for (price, expected) in [(29,90),(30,10),(49,10),(50,20),(99,20),(100,30),(499,30),(500,40),(999,40),(1000,50),(1999,50),(2000,60),(9000,60)] {
            XCTAssertEqual(tiers.lifetime(price:price,officialRemaining:90,officialTotal:90)?.duration,Double(expected),"price \(price)")
        }
        XCTAssertEqual(SCLifetimePolicy(["mode":"tiers", "tiers":["30":NSNull()]]).lifetime(price:30,officialRemaining:50,officialTotal:60)?.duration,50)
    }

    func testOnlyIntegerSecondsAcceptedAndOfficialExpiryStillWins() {
        for invalid in [true,"30",0,-1,7201,1.5,Double.nan,Double.infinity,NSNull()] as [Any] {
            let rule = SCLifetimePolicy(["mode":"uniform","uniformSeconds":invalid,"tiers":["30":invalid]])
            XCTAssertEqual(rule.uniformSeconds,60); XCTAssertNil(rule.tiers[30])
        }
        XCTAssertEqual(SCLifetimePolicy(["mode":"unknown"]).mode,.official)
        let rule = SCLifetimePolicy(["mode":"uniform","uniformSeconds":7200])
        XCTAssertNil(rule.lifetime(price:30,officialRemaining:0,officialTotal:60))
        XCTAssertNil(rule.lifetime(price:30,officialRemaining:-1,officialTotal:60))
        XCTAssertNil(rule.lifetime(price:30,officialRemaining:.nan,officialTotal:60))
        XCTAssertNil(SCLifetimePolicy(["mode":"uniform","uniformSeconds":10]).lifetime(price:30,officialRemaining:40,officialTotal:60))
    }

    func testSettingsOnlyAffectNewMessagesAndSnapshotsDeductAge() {
        var store = PiPMessageStore()
        store.scLifetime = SCLifetimePolicy(["mode":"uniform","uniformSeconds":120])
        store.receive(packet(1),edge:10,now:120)
        XCTAssertEqual(store.items.first?.duration,100)
        store.scLifetime = SCLifetimePolicy(["mode":"uniform","uniformSeconds":10])
        store.receive(packet(1),edge:15,now:125)
        XCTAssertEqual(store.items.count,1); XCTAssertEqual(store.items.first?.duration,100)
        store.receive(packet(2,end:185),edge:15,now:125)
        XCTAssertEqual(store.items.last?.duration,10)
        XCTAssertEqual(store.visible(time:26,edge:26,rows:5,chat:false,sc:true).map(\.id),["1"])
    }

    func testExpiredDeletedAndClearedMessagesNeverReappearAfterRuleChanges() {
        var store = PiPMessageStore()
        store.scLifetime = SCLifetimePolicy(["mode":"uniform","uniformSeconds":5])
        store.receive(packet(1),edge:10,now:100)
        XCTAssertTrue(store.visible(time:50,edge:50,rows:5,chat:false,sc:true).isEmpty)
        store.scLifetime = SCLifetimePolicy(["mode":"uniform","uniformSeconds":120])
        store.receive(packet(1),edge:50,now:140)
        XCTAssertTrue(store.items.isEmpty)
        store.receive(packet(2,end:200),edge:50,now:140)
        store.receive(["cmd":"SUPER_CHAT_MESSAGE_DELETE","data":["ids":[2]]],edge:50,now:140)
        store.receive(packet(2,end:200),edge:50,now:140)
        XCTAssertTrue(store.items.isEmpty)
        store.receive(packet(3,end:200),edge:50,now:140)
        store.clearMessages(); store.receive(packet(3,end:200),edge:51,now:141)
        XCTAssertTrue(store.items.isEmpty)
        store.receive(packet(5,end:200),edge:51,now:141); store.dismissSC("5")
        store.receive(packet(5,end:200),edge:52,now:142); XCTAssertTrue(store.items.isEmpty)
        store.scLifetime = SCLifetimePolicy(["mode":"uniform","uniformSeconds":5])
        store.receive(packet(4,end:160),edge:50,now:150)
        store.scLifetime = SCLifetimePolicy(["mode":"uniform","uniformSeconds":120])
        store.receive(packet(4,end:160),edge:51,now:151)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testManualMediaRestartKeepsOnlyRemainingSCAndDoesNotReapplySettings() {
        var store=PiPMessageStore()
        store.scLifetime=SCLifetimePolicy(["mode":"uniform","uniformSeconds":120])
        store.receive(packet(1),edge:10,now:100)
        store.restartMedia(time:30)
        XCTAssertEqual(store.items.first?.duration,100); XCTAssertNil(store.items.first?.at)
        store.scLifetime=SCLifetimePolicy(["mode":"uniform","uniformSeconds":7200])
        store.restartMedia(time:0)
        XCTAssertEqual(store.visible(time:0,edge:0,rows:5,chat:false,sc:true).first?.duration,100)
        XCTAssertTrue(store.visible(time:101,edge:101,rows:5,chat:false,sc:true).isEmpty)
        store.receive(packet(1,end:500),edge:101,now:450)
        XCTAssertTrue(store.visible(time:101,edge:101,rows:5,chat:false,sc:true).isEmpty)
    }

    @MainActor func testForegroundJavaScriptAndNativePiPUseIdenticalLifetimes() throws {
        let context = try XCTUnwrap(JSContext())
        let url = try XCTUnwrap(Bundle.main.url(forResource:"core",withExtension:"js",subdirectory:"Web"))
        context.evaluateScript(try String(contentsOf:url,encoding:.utf8))
        XCTAssertNil(context.exception)
        let policies: [JSON] = [[:], ["mode":"uniform","uniformSeconds":120], ["mode":"uniform","uniformSeconds":5],
            ["mode":"tiers","tiers":["30":15,"50":45,"100":NSNull(),"2000":600]],
            ["mode":"uniform","uniformSeconds":"120"]]
        var id=100
        for policy in policies { for price in [30,50,100,2000] { for age in [0,10,59,60] {
            id += 1
            let incoming=packet(id,price:price), now=100+age
            func json(_ value: Any) throws -> String { String(data:try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]),encoding:.utf8)! }
            let script="JSON.stringify(FusionCore.normalize(\(try json(incoming)),new FusionCore.EmojiBook(),\(now*1000),\(try json(policy))))"
            let result=try XCTUnwrap(context.evaluateScript(script)?.toString()); XCTAssertNil(context.exception)
            var store=PiPMessageStore(); store.scLifetime=SCLifetimePolicy(policy); store.receive(incoming,edge:10,now:Double(now))
            let web=(try JSONSerialization.jsonObject(with:Data(result.utf8),options:[.fragmentsAllowed])) as? JSON
            if let duration=(web?["duration"] as? NSNumber)?.doubleValue, duration>0 {
                XCTAssertEqual(try XCTUnwrap(store.items.first).duration,duration,accuracy:0.000001)
            } else { XCTAssertTrue(store.items.isEmpty) }
        } } }
    }
}
