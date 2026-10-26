import XCTest
import AVFoundation
import Network
@testable import Fusion

/// A genuine loopback live HLS origin: three 3-second TS segments per window.
/// The gate is armed only after playback advances; held HTTP requests are released intact.
private final class GatedHLSOrigin {
    private let listener:NWListener,queue=DispatchQueue(label:"fusion.test.hls-gate"),lock=NSLock()
    private let segments:[Data]
    private var readyPort:UInt16=0,gated=false,released=false,stopped=false
    private var pending=[(NWConnection,String)](),connections=[ObjectIdentifier:NWConnection]()
    var port:UInt16{lock.lock();defer{lock.unlock()};return readyPort}
    var heldRequests:Int{lock.lock();defer{lock.unlock()};return pending.count}
    init(segments:[Data])throws{
        self.segments=segments
        let parameters=NWParameters.tcp;parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
        listener=try NWListener(using:parameters)
        listener.stateUpdateHandler={ [weak self] state in guard let self else{return};if case .ready=state{self.lock.lock();self.readyPort=self.listener.port?.rawValue ?? 0;self.lock.unlock()} }
        listener.newConnectionHandler={ [weak self] connection in guard let self else{return};self.lock.lock();self.connections[ObjectIdentifier(connection)]=connection;self.lock.unlock();connection.start(queue:self.queue);self.receive(connection,Data()) }
        listener.start(queue:queue)
    }
    func arm(){lock.lock();gated=true;lock.unlock()}
    func release(){lock.lock();released=true;let waiting=pending;pending.removeAll();lock.unlock();for(connection,path)in waiting{respond(connection,path)}}
    func stop(){lock.lock();stopped=true;let all=Array(connections.values);connections.removeAll();pending.removeAll();lock.unlock();listener.cancel();for c in all{c.cancel()}}
    private func receive(_ c:NWConnection,_ previous:Data){
        c.receive(minimumIncompleteLength:1,maximumLength:16384){[weak self] bytes,_,done,error in
            guard let self else{return};var data=previous;if let bytes{data.append(bytes)}
            if let text=String(data:data,encoding:.utf8),text.contains("\r\n\r\n"),let line=text.components(separatedBy:"\r\n").first{
                let pieces=line.split(separator:" ");guard pieces.count>=2 else{c.cancel();return}
                let path=String(pieces[1]).components(separatedBy:"?")[0]
                self.lock.lock();let hold=self.gated && !self.released && path=="/stream.m3u8";if hold{self.pending.append((c,path))};self.lock.unlock()
                if !hold{self.respond(c,path)}
            }else if done || error != nil || data.count>16384{c.cancel()}
            else{self.receive(c,data)}
        }
    }
    private func respond(_ c:NWConnection,_ path:String){
        lock.lock();let advanced=released,closed=stopped;lock.unlock();guard !closed else{c.cancel();return}
        let body:Data,type:String
        if path=="/stream.m3u8"{
            let first=advanced ? 3:0
            let list="#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:\(first)\n"+(first..<(first+3)).map{"#EXTINF:3.000,\nsegment-\($0).ts\n"}.joined()
            body=Data(list.utf8);type="application/vnd.apple.mpegurl"
        }else if path.hasPrefix("/segment-"),path.hasSuffix(".ts"),let index=Int(path.dropFirst(9).dropLast(3)),segments.indices.contains(index){body=segments[index];type="video/MP2T"}
        else{c.cancel();return}
        var response=Data("HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8);response.append(body)
        c.send(content:response,completion:.contentProcessed{[weak self] _ in c.cancel();guard let self else{return};self.lock.lock();self.connections.removeValue(forKey:ObjectIdentifier(c));self.lock.unlock()})
    }
    deinit{listener.cancel()}
}

final class BufferingRecoveryTests:XCTestCase {
    /// Repackage the project's generated stereo AAC/H.264 fixture into continuous 3s TS.
    /// This is the existing legacy remux function, not model inference or a live recording.
    private func tsSegments()throws->[Data]{
        let root=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"Fixtures",withExtension:nil)),initial=try Data(contentsOf:root.appendingPathComponent("init.mp4"))
        return try (0..<6).map{group in
            var mp4=initial;for i in (group*3)..<(group*3+3){mp4.append(try Data(contentsOf:root.appendingPathComponent("segment-\(i).m4s")))}
            var pointer:UnsafeMutablePointer<UInt8>?,length=0
            let status=mp4.withUnsafeBytes{fusion_voice_segment($0.bindMemory(to:UInt8.self).baseAddress,mp4.count,0.001,&pointer,&length)}
            XCTAssertEqual(status,1,"Offline fixture must really become MPEG-TS")
            let bytes=try XCTUnwrap(pointer);defer{fusion_voice_free(bytes)};return Data(bytes:bytes,count:length)
        }
    }
    @MainActor private func wait(_ seconds:Double,_ description:String,_ condition:()->Bool)async throws{
        for _ in 0..<Int(seconds*10){if condition(){return};try await Task.sleep(nanoseconds:100_000_000)}
        XCTFail(description);throw FusionError(description)
    }
    @MainActor private func depletedPlayer()async throws->(NativePlayer,GatedHLSOrigin){
        let origin=try GatedHLSOrigin(segments:tsSegments()),p=NativePlayer()
        do{
            try await wait(5,"Loopback HLS origin did not become ready"){origin.port>0}
            p.open(url:URL(string:"http://127.0.0.1:\(origin.port)/stream.m3u8")!,token:"gated-original",volume:0);p.player.isMuted=true;p.play()
            try await wait(12,"HLS must advance before the network gate is armed"){p.player.currentTime().seconds>0.3 && p.player.timeControlStatus == .playing}
            origin.arm()
            try await wait(16,"Already playing HLS did not actually exhaust its available media"){origin.heldRequests>0 && p.player.timeControlStatus != .playing && (p.snapshot()["bufferedAhead"] as? Double ?? 99)<0.3}
            XCTAssertGreaterThan(p.player.currentTime().seconds,0.3);XCTAssertEqual(p.snapshot()["paused"] as? Bool,false)
            XCTAssertEqual(p.snapshot()["rate"] as? Double,0);XCTAssertLessThan(p.snapshot().int("readyState"),3)
            XCTAssertEqual(p.snapshot()["ranges"] as? [[Double]],p.snapshot()["loaded"] as? [[Double]])
            return(p,origin)
        }catch{p.close();origin.stop();throw error}
    }
    @MainActor func testThreeSegmentLiveHLSDepletesThenRefillsWithoutReplacingItemOrSeeking()async throws{
        let(p,origin)=try await depletedPlayer();defer{p.close();origin.stop()}
        let item=p.player.currentItem,stopped=p.player.currentTime().seconds,requests=p.playRequests
        XCTAssertTrue(p.player.automaticallyWaitsToMinimizeStalling);XCTAssertEqual(item?.preferredForwardBufferDuration,0)
        var seeks=0;p.seekDriver={_,_,complete in seeks += 1;complete(false)}
        origin.release()
        try await wait(12,"Original HLS item did not resume after its held HTTP response was released"){p.player.currentTime().seconds>stopped+0.35 && p.player.timeControlStatus == .playing}
        XCTAssertTrue(p.player.currentItem === item);XCTAssertEqual(p.token,"gated-original");XCTAssertEqual(seeks,0)
        XCTAssertLessThan(p.player.currentTime().seconds,stopped+3,"Refill must continue the old playhead, not jump to a new live edge")
        XCTAssertLessThanOrEqual(p.playRequests-requests,1,"Do not keep reissuing play while AVFoundation is already waiting")
        XCTAssertGreaterThan(p.snapshot()["rate"] as? Double ?? 0,0)
    }
    @MainActor func testRefillCannotCancelExplicitPauseOrDelayHoldButExplicitContinueUsesSameItem()async throws{
        let(p,origin)=try await depletedPlayer();defer{p.close();origin.stop()}
        let item=p.player.currentItem,stopped=p.player.currentTime().seconds
        p.pause() // The Web delay-hold path also deliberately calls this same native pause.
        origin.release();try await Task.sleep(nanoseconds:1_000_000_000)
        XCTAssertEqual(p.player.rate,0);XCTAssertEqual(p.snapshot()["paused"] as? Bool,true);XCTAssertEqual(p.player.currentTime().seconds,stopped,accuracy:0.1)
        p.play();try await wait(10,"Manual continue did not resume the retained item"){p.player.currentTime().seconds>stopped+0.25}
        XCTAssertTrue(p.player.currentItem === item);XCTAssertEqual(p.token,"gated-original")
    }
    @MainActor func testReadyItemFailureNoticeDoesNotFabricatePauseOrTerminalError()async throws{
        // This checks notification handling on a ready item, not live-origin startup.
        // A permanently unchanged 9s live playlist may never start on a cold simulator.
        // The separate gated-HLS tests above still require real starvation and refill.
        let root=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"Fixtures",withExtension:nil))
        var data=try Data(contentsOf:root.appendingPathComponent("init.mp4"))
        for i in 0..<18{data.append(try Data(contentsOf:root.appendingPathComponent("segment-\(i).m4s")))}
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        let p=NativePlayer();defer{p.close();try? FileManager.default.removeItem(at:path)}
        try data.write(to:path)
        p.open(url:path,token:"nonterminal",volume:0);p.player.isMuted=true;p.play()
        try await wait(12,"Ready-item notification fixture did not advance"){p.player.currentItem?.status == .readyToPlay && p.player.timeControlStatus == .playing && p.player.currentTime().seconds>0.3}
        let item=try XCTUnwrap(p.player.currentItem),time=p.player.currentTime().seconds,requests=p.playRequests
        NotificationCenter.default.post(name:AVPlayerItem.failedToPlayToEndTimeNotification,object:item,userInfo:[AVPlayerItemFailedToPlayToEndTimeErrorKey:NSError(domain:"FusionSyntheticTransport",code:503)])
        try await Task.sleep(nanoseconds:300_000_000)
        XCTAssertTrue(p.player.currentItem === item);XCTAssertEqual(p.snapshot()["paused"] as? Bool,false)
        XCTAssertEqual(p.snapshot().str("error"),"");XCTAssertEqual(p.playRequests,requests)
        XCTAssertGreaterThan(p.player.currentTime().seconds,time)
        p.pause()
        NotificationCenter.default.post(name:AVPlayerItem.failedToPlayToEndTimeNotification,object:item)
        try await Task.sleep(nanoseconds:100_000_000);XCTAssertTrue(p.snapshot()["paused"] as? Bool ?? false);XCTAssertEqual(p.player.rate,0)
    }
    @MainActor func testWaitingRequestedRateDoesNotAdvanceWebClockOrMessageReadiness(){
        for control in [AVPlayer.TimeControlStatus.waitingToPlayAtSpecifiedRate,.paused]{
            let state=NativePlayer.transportProjection(ready:true,control:control,requestedRate:1,desiredPaused:false,seeking:false,suspended:false,bufferedAhead:8)
            XCTAssertEqual(state.rate,0);XCTAssertEqual(state.state,2)
        }
        for flags in [(true,false),(false,true)]{
            let state=NativePlayer.transportProjection(ready:true,control:.playing,requestedRate:1,desiredPaused:false,seeking:flags.0,suspended:flags.1,bufferedAhead:8)
            XCTAssertEqual(state.rate,0);XCTAssertLessThan(state.state,3)
        }
        let playing=NativePlayer.transportProjection(ready:true,control:.playing,requestedRate:1,desiredPaused:false,seeking:false,suspended:false,bufferedAhead:1)
        XCTAssertEqual(playing.rate,1);XCTAssertEqual(playing.state,4)
    }
    @MainActor func testRepeatedPlayRequestsWhilePlayingOrWaitingAreIdempotent()async throws{
        let origin=try GatedHLSOrigin(segments:tsSegments()),p=NativePlayer();defer{p.close();origin.stop()}
        try await wait(5,"Origin not ready"){origin.port>0}
        p.open(url:URL(string:"http://127.0.0.1:\(origin.port)/stream.m3u8")!,token:"idempotent",volume:0);p.player.isMuted=true;p.play()
        try await wait(12,"Fixture did not play"){p.player.timeControlStatus == .playing}
        let requests=p.playRequests;for _ in 0..<30{p.play()};XCTAssertEqual(p.playRequests,requests)
        p.enterBackground(continueAudio:false);let item=p.player.currentItem
        NotificationCenter.default.post(name:AVPlayerItem.playbackStalledNotification,object:item)
        try await Task.sleep(nanoseconds:200_000_000);XCTAssertEqual(p.player.rate,0);XCTAssertTrue(p.isSuspended);XCTAssertTrue(p.player.currentItem === item)
    }
}
