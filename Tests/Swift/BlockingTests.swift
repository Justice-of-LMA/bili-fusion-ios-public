import XCTest
@testable import Fusion
final class BlockingTests: XCTestCase {
 func testPlatformScopedUserAndLiteralKeywordRules() {
  let rules = BlockRules.normalize(["users":[["platform":"bilibili","uid":"123","name":"旧昵称"]],"keywords":[" 广告 ","a.B"]])
  XCTAssertTrue(BlockRules.matches(rules,uid:"123",name:"改名",text:"正常"))
  XCTAssertFalse(BlockRules.matches(rules,uid:"124",name:"旧昵称",text:"正常"))
  XCTAssertFalse(BlockRules.matches(rules,uid:"123",name:"旧昵称",text:"正常",platform:"huya"))
  XCTAssertTrue(BlockRules.matches(rules,uid:"",name:"",text:"AA.BC"))
  XCTAssertFalse(BlockRules.matches(rules,uid:"",name:"",text:"axB"))
  let fallback = BlockRules.normalize(["users":[["uid":"0","name":"无ID"]]])
  XCTAssertTrue(BlockRules.matches(fallback,uid:"0",name:"无ID",text:"正常"))
  XCTAssertFalse(BlockRules.matches(fallback,uid:"0",name:"其他人",text:"正常"))
 }
 func testPiPClearsQueuedAndVisibleMatchesAndRetainsRulesOnPause() {
  var store = PiPMessageStore()
  let blocked: JSON = ["cmd":"DANMU_MSG","info":[[],"待屏蔽消息",[123,"测试用户"]]]
  store.receive(blocked,edge:20)
  store.receive(["cmd":"SUPER_CHAT_MESSAGE","data":["id":1,"uid":123,"message":"测试SC","price":30,"time":60,"user_info":["uname":"测试用户"]]],edge:20)
  XCTAssertEqual(store.items.count,2)
  store.setBlocking(["users":[["platform":"bilibili","uid":"123","name":"测试用户"]]])
  XCTAssertTrue(store.items.isEmpty)
  store.clearMessages(); store.receive(blocked,edge:20); XCTAssertTrue(store.items.isEmpty)
  store.receive(["cmd":"DANMU_MSG","info":[[],"同名不同ID",[124,"测试用户"]]],edge:20)
  XCTAssertEqual(store.items.count,1)
  store.setBlocking(["keywords":["同名"]]); XCTAssertTrue(store.items.isEmpty)
  store.setBlocking([:]); store.receive(blocked,edge:20); XCTAssertEqual(store.items.count,1)
 }
}
