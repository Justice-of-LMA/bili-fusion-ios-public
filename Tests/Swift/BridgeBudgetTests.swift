import XCTest
@testable import Fusion

final class BridgeBudgetTests:XCTestCase {
    func testSixteenSlowMetadataCallsCannotDiscardPlayPauseOrVolume(){
        var budget=BridgeBudget()
        for _ in 0..<16{XCTAssertEqual(budget.acquire("snapshot"),.network)}
        XCTAssertNil(budget.acquire("emojis"))
        for op in ["mediaPlay","mediaPause","mediaVolume","mediaAudioOnly","mediaClose","fullscreen"]{XCTAssertEqual(budget.acquire(op),.playback)}
        XCTAssertEqual(budget.network,16);XCTAssertEqual(budget.playback,6)
        for _ in 0..<6{budget.release(.playback)}
        XCTAssertEqual(budget.playback,0);XCTAssertEqual(budget.network,16)
        budget.release(.network);XCTAssertEqual(budget.acquire("preview"),.network)
    }
    func testPlaybackLaneIsAlsoBoundedAndDoesNotLetChatSendingBypassItsLane(){
        var budget=BridgeBudget()
        for _ in 0..<16{XCTAssertEqual(budget.acquire("mediaSeek"),.playback)}
        XCTAssertNil(budget.acquire("mediaPlay"));XCTAssertEqual(budget.acquire("send"),.network)
        budget.release(.playback);XCTAssertEqual(budget.acquire("mediaPause"),.playback)
        for _ in 0..<32{budget.release(.playback)}
        XCTAssertEqual(budget.playback,0);XCTAssertEqual(budget.network,1)
    }
}
