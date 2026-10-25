import XCTest
import AVFoundation
@testable import Fusion

final class SeekTests:XCTestCase {
    @MainActor private func loadedPlayer() async throws -> (NativePlayer,URL) {
        let root=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"Fixtures",withExtension:nil))
        var data=try Data(contentsOf:root.appendingPathComponent("init.mp4"))
        for i in 0..<8{data.append(try Data(contentsOf:root.appendingPathComponent("segment-\(i).m4s")))}
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        try data.write(to:path);let p=NativePlayer();p.open(url:path,token:"seek-test",volume:0);p.player.isMuted=true;p.play()
        for _ in 0..<100{if p.player.currentTime().seconds>0.3 && !(p.snapshot()["loaded"] as? [[Double]] ?? []).isEmpty{return(p,path)};try await Task.sleep(nanoseconds:100_000_000)}
        p.close();try? FileManager.default.removeItem(at:path);throw FusionError("Local seek fixture did not load")
    }
    @MainActor func testMissingSeekCompletionTimesOutWithoutReloadOrPermanentSeeking()async throws {
        let(p,path)=try await loadedPlayer();defer{p.close();try? FileManager.default.removeItem(at:path)}
        let item=p.player.currentItem;p.seekDeadline=50_000_000;p.seekDriver={_,_,_ in}
        do{try await p.seek(0.2);XCTFail("Missing completion must be reported")}catch{XCTAssertTrue(error.localizedDescription.contains("超时"))}
        XCTAssertEqual(p.snapshot()["seeking"] as? Bool,false);XCTAssertEqual(p.snapshot()["paused"] as? Bool,true);XCTAssertTrue(p.player.currentItem === item)
    }
    @MainActor func testPauseDuringSeekIsPreservedAndLoadedRangesAreNotFutureSeekableWindow()async throws {
        let(p,path)=try await loadedPlayer();defer{p.close();try? FileManager.default.removeItem(at:path)}
        let snapshot=p.snapshot();XCTAssertEqual(snapshot["ranges"] as? [[Double]],snapshot["loaded"] as? [[Double]])
        p.seekDriver={_,_,complete in DispatchQueue.main.asyncAfter(deadline:.now()+0.1){complete(true)}}
        let task=Task{@MainActor in try await p.seek(0.2)};await Task.yield();p.pause();try await task.value
        XCTAssertEqual(p.snapshot()["seeking"] as? Bool,false);XCTAssertEqual(p.snapshot()["paused"] as? Bool,true);XCTAssertEqual(p.player.rate,0)
    }
}
