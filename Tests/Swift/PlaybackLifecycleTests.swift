import XCTest
import UIKit
import AVFoundation
import AVKit
import WebKit
@testable import Fusion

/// Only the project's generated local MP4 fixture is used. No rooms, accounts or messages.
final class PlaybackLifecycleTests:XCTestCase {
    @MainActor private func fixturePlayer(segments:Int=12)async throws->(NativePlayer,URL){
        let directory=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"Fixtures",withExtension:nil))
        var data=try Data(contentsOf:directory.appendingPathComponent("init.mp4"))
        for i in 0..<segments{data.append(try Data(contentsOf:directory.appendingPathComponent("segment-\(i).m4s")))}
        let path=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        try data.write(to:path)
        let p=NativePlayer();p.open(url:path,token:"lifecycle-fixture",volume:0.35);p.player.isMuted=true;p.play()
        for _ in 0..<80{if p.player.currentItem?.status == .readyToPlay,p.player.currentTime().seconds>0.2{return(p,path)};try await Task.sleep(nanoseconds:100_000_000)}
        p.close();try? FileManager.default.removeItem(at:path);throw FusionError("Offline lifecycle fixture did not start")
    }
    @MainActor func testAudioBackgroundDetachesOnlyPresentationAndForegroundKeepsItemClockAndIntent()async throws{
        let(p,path)=try await fixturePlayer();defer{p.close();try? FileManager.default.removeItem(at:path)}
        let item=p.player.currentItem,before=p.player.currentTime().seconds,token=p.token
        p.surface.zoom(scale:2,x:20,y:10)
        p.enterBackground(continueAudio:true)
        XCTAssertNil(p.surface.videoLayer.player);XCTAssertFalse(p.isSuspended);XCTAssertEqual(p.snapshot()["paused"] as? Bool,false)
        try await Task.sleep(nanoseconds:300_000_000)
        p.enterForeground()
        XCTAssertTrue(p.player.currentItem === item);XCTAssertTrue(p.surface.videoLayer.player === p.player);XCTAssertEqual(p.token,token)
        XCTAssertGreaterThan(p.player.currentTime().seconds,before+0.1);XCTAssertEqual(p.player.volume,0.35);XCTAssertEqual(p.surface.videoScale,2)
        XCTAssertEqual(p.snapshot()["seeking"] as? Bool,false);XCTAssertFalse(p.isSuspended)
    }
    @MainActor func testTemporaryBackgroundPauseResumesOnlyNonUserPausedTrackAtSameBufferedPosition()async throws{
        let(p,path)=try await fixturePlayer();defer{p.close();try? FileManager.default.removeItem(at:path)}
        let item=p.player.currentItem;p.enterBackground(continueAudio:false);let pausedAt=p.player.currentTime().seconds
        XCTAssertTrue(p.isSuspended);XCTAssertEqual(p.snapshot()["paused"] as? Bool,false);XCTAssertEqual(p.player.rate,0)
        try await Task.sleep(nanoseconds:200_000_000);XCTAssertEqual(p.player.currentTime().seconds,pausedAt,accuracy:0.05)
        p.enterForeground();XCTAssertTrue(p.player.currentItem === item);XCTAssertEqual(p.token,"lifecycle-fixture")
        try await Task.sleep(nanoseconds:200_000_000);XCTAssertGreaterThan(p.player.currentTime().seconds,pausedAt+0.05)
        p.pause();let userPausedAt=p.player.currentTime().seconds;p.enterBackground(continueAudio:true);p.enterForeground()
        try await Task.sleep(nanoseconds:150_000_000);XCTAssertEqual(p.player.rate,0);XCTAssertEqual(p.player.currentTime().seconds,userPausedAt,accuracy:0.05);XCTAssertEqual(p.snapshot()["paused"] as? Bool,true)
    }
    @MainActor func testInterruptionsAndHeadphoneRemovalDoNotBecomeUnsolicitedPlaybackOnForeground()async throws{
        let(p,path)=try await fixturePlayer();defer{p.close();try? FileManager.default.removeItem(at:path)}
        let item=p.player.currentItem;p.interruptionBegan();p.interruptionEnded(shouldResume:false);p.enterForeground()
        XCTAssertTrue(p.isSuspended);XCTAssertEqual(p.player.rate,0);XCTAssertTrue(p.player.currentItem === item)
        p.play();XCTAssertFalse(p.isSuspended)
        p.interruptionBegan();p.pause();p.interruptionEnded(shouldResume:true);p.enterForeground()
        XCTAssertEqual(p.snapshot()["paused"] as? Bool,true);XCTAssertEqual(p.player.rate,0)
        p.play();p.routeDisconnected();p.enterBackground(continueAudio:true);p.enterForeground()
        XCTAssertTrue(p.isSuspended);XCTAssertEqual(p.player.rate,0);p.play();XCTAssertFalse(p.isSuspended);XCTAssertTrue(p.player.currentItem === item)
    }
    @MainActor func testSeekCompletionDuringBackgroundPauseCannotStartPlaybackBehindUser()async throws{
        let(p,path)=try await fixturePlayer();defer{p.close();try? FileManager.default.removeItem(at:path)}
        let item=p.player.currentItem;p.seekDriver={_,_,complete in DispatchQueue.main.asyncAfter(deadline:.now()+0.1){complete(true)}}
        let task=Task{@MainActor in try await p.seek(0.1)};await Task.yield();p.enterBackground(continueAudio:false);try await task.value
        XCTAssertEqual(p.snapshot()["seeking"] as? Bool,false);XCTAssertEqual(p.player.rate,0);XCTAssertTrue(p.isSuspended);XCTAssertTrue(p.player.currentItem === item)
        p.enterForeground();XCTAssertFalse(p.isSuspended);XCTAssertEqual(p.snapshot()["paused"] as? Bool,false)
    }
    @MainActor func testMessagePiPOnlySuspendsAWithoutErasingItsPlaybackChoice()async throws{
        let(p,path)=try await fixturePlayer();defer{p.close();try? FileManager.default.removeItem(at:path)}
        let item=p.player.currentItem;p.setMessagePiPOnly(true);XCTAssertEqual(p.player.rate,0);XCTAssertTrue(p.wantsPlayback)
        p.enterBackground(continueAudio:true);p.setMessagePiPOnly(false);p.enterForeground();XCTAssertFalse(p.isSuspended);XCTAssertTrue(p.player.currentItem === item)
        p.pause();p.setMessagePiPOnly(true);p.setMessagePiPOnly(false);XCTAssertEqual(p.snapshot()["paused"] as? Bool,true)
    }
    @MainActor func testNativeControllerSceneTransitionPreservesBothExistingItemsAndDoesNotCreateConnections()async throws{
        let(p,path)=try await fixturePlayer();defer{p.close();try? FileManager.default.removeItem(at:path)}
        // A controller without a Web view cannot start page status requests. Exercise its
        // scene coordinator directly around local AVPlayer items, not platform resolution.
        let controller=FusionController()
        let mirror=Mirror(reflecting:controller)
        let players=try XCTUnwrap(mirror.children.first{$0.label=="players"}?.value as? [String:NativePlayer])
        let a=try XCTUnwrap(players["A"]),b=try XCTUnwrap(players["B"])
        defer{a.close();b.close();controller.sceneForeground()}
        a.open(url:path,token:"controller-A",volume:0.25);b.open(url:path,token:"controller-B",volume:0.5);a.play();b.pause()
        let aItem=a.player.currentItem,bItem=b.player.currentItem
        _=try controller.setBackgroundMode("pause");controller.sceneBackground()
        XCTAssertTrue(a.isSuspended);XCTAssertTrue(a.player.currentItem === aItem);XCTAssertTrue(b.player.currentItem === bItem)
        controller.sceneForeground();XCTAssertEqual(a.token,"controller-A");XCTAssertEqual(b.token,"controller-B");XCTAssertFalse(a.isSuspended);XCTAssertTrue(a.wantsPlayback);XCTAssertFalse(b.wantsPlayback)
        XCTAssertTrue(a.player.currentItem === aItem);XCTAssertTrue(b.player.currentItem === bItem)
        let state=controller.lifecycleState();XCTAssertEqual(state["foreground"] as? Bool,true)
        XCTAssertTrue((mirror.children.first{$0.label=="sockets"}?.value as? [String:any ChatConnection])?.isEmpty==true)
        XCTAssertFalse(controller.isMediaProxyRunning,"No open/resolve/proxy restart in a scene transition")
    }
    @MainActor func testActualAudioSessionNotificationsKeepUserPauseAndOriginalItems()async throws{
        let(p,path)=try await fixturePlayer();defer{p.close();try? FileManager.default.removeItem(at:path)}
        let delegate=try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate),controller=try XCTUnwrap(delegate.window?.rootViewController as? FusionController)
        controller.loadViewIfNeeded();let mirror=Mirror(reflecting:controller)
        let players=try XCTUnwrap(mirror.children.first{$0.label=="players"}?.value as? [String:NativePlayer]),a=try XCTUnwrap(players["A"]),b=try XCTUnwrap(players["B"])
        defer{a.close();b.close()}
        a.open(url:path,token:"session-A",volume:0.25);b.open(url:path,token:"session-B",volume:0);a.play();b.pause();let aItem=a.player.currentItem,bItem=b.player.currentItem
        func post(_ type:AVAudioSession.InterruptionType,_ options:AVAudioSession.InterruptionOptions=[]){NotificationCenter.default.post(name:AVAudioSession.interruptionNotification,object:AVAudioSession.sharedInstance(),userInfo:[AVAudioSessionInterruptionTypeKey:NSNumber(value:type.rawValue),AVAudioSessionInterruptionOptionKey:NSNumber(value:options.rawValue)])}
        post(.began);XCTAssertTrue(a.isSuspended);XCTAssertEqual(a.player.rate,0);XCTAssertTrue(a.player.currentItem === aItem)
        post(.ended,.shouldResume);XCTAssertFalse(a.isSuspended);XCTAssertTrue(a.wantsPlayback);XCTAssertFalse(b.wantsPlayback);XCTAssertEqual(b.player.rate,0)
        post(.began);a.pause();post(.ended,.shouldResume);XCTAssertFalse(a.wantsPlayback);XCTAssertEqual(a.player.rate,0)
        XCTAssertTrue(a.player.currentItem === aItem);XCTAssertTrue(b.player.currentItem === bItem);XCTAssertEqual(a.token,"session-A");XCTAssertEqual(b.token,"session-B")
    }
    @MainActor func testFullscreenInsetsAndManualOrientationUseNativeWindowScene()async throws{
        let delegate=try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate),controller=try XCTUnwrap(delegate.window?.rootViewController as? FusionController)
        controller.loadViewIfNeeded();let old=controller.lifecycleState(),oldOrientation=controller.orientationChoice
        defer{controller.setNativeFullscreen(old["full"] as? Bool ?? false);_ = try? controller.requestOrientation(oldOrientation)}
        let web=try XCTUnwrap(controller.view.subviews.compactMap{$0 as? WKWebView}.first)
        controller.setNativeFullscreen(true);controller.view.layoutIfNeeded()
        for _ in 0..<20{controller.view.layoutIfNeeded();if abs(web.frame.minY)<1 && abs(web.frame.maxY-controller.view.bounds.maxY)<1{break};try await Task.sleep(nanoseconds:50_000_000)}
        XCTAssertTrue(controller.prefersStatusBarHidden);XCTAssertEqual(web.frame.minX,0,accuracy:1);XCTAssertEqual(web.frame.maxX,controller.view.bounds.maxX,accuracy:1)
        XCTAssertEqual(web.frame.minY,0,accuracy:1);XCTAssertEqual(web.frame.maxY,controller.view.bounds.maxY,accuracy:1)
        _=try controller.requestOrientation("landscape");XCTAssertEqual(controller.supportedInterfaceOrientations,.landscape)
        for _ in 0..<30{controller.view.layoutIfNeeded();if web.bounds.width>web.bounds.height{break};try await Task.sleep(nanoseconds:100_000_000)}
        XCTAssertGreaterThan(web.bounds.width,web.bounds.height,"Manual landscape must produce a real wide WK viewport, even when a resizable iPad window refuses system rotation")
        XCTAssertEqual(controller.presentationOrientation,"landscape");if controller.view.bounds.width<controller.view.bounds.height{XCTAssertNotEqual(web.transform,.identity,"A portrait system window must physically rotate the app presentation, not only relabel it")};XCTAssertEqual(web.frame.width,controller.view.bounds.width,accuracy:1);XCTAssertEqual(web.frame.height,controller.view.bounds.height,accuracy:1)
        _=try controller.requestOrientation("portrait");XCTAssertEqual(controller.supportedInterfaceOrientations,.portrait)
        for _ in 0..<30{controller.view.layoutIfNeeded();if web.bounds.height>web.bounds.width{break};try await Task.sleep(nanoseconds:100_000_000)}
        XCTAssertGreaterThan(web.bounds.height,web.bounds.width);XCTAssertEqual(controller.presentationOrientation,"portrait")
        XCTAssertThrowsError(try controller.requestOrientation("sideways"));XCTAssertThrowsError(try controller.setBackgroundMode("unbounded"))
    }
    @MainActor func testSystemVideoPiPStartsFromExistingLocalPlayerAndClosesWithoutReplacingItem()async throws{
        let manager=VideoPictureInPicture();guard manager.supported else{throw XCTSkip("System video PiP not supported on this simulator")}
        try AVAudioSession.sharedInstance().setCategory(.playback,mode:.moviePlayback,options:[.mixWithOthers]);try AVAudioSession.sharedInstance().setActive(true)
        let(p,path)=try await fixturePlayer(segments:24)
        let delegate=try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate),host=try XCTUnwrap(delegate.window?.rootViewController?.view)
        defer{manager.stop();p.close();p.surface.removeFromSuperview();try? FileManager.default.removeItem(at:path)}
        p.surface.frame=CGRect(x:20,y:20,width:320,height:180);p.surface.isHidden=false;host.addSubview(p.surface);p.surface.layoutIfNeeded()
        for _ in 0..<50{if p.surface.videoLayer.isReadyForDisplay{break};try await Task.sleep(nanoseconds:100_000_000)}
        XCTAssertTrue(p.surface.videoLayer.isReadyForDisplay);let item=p.player.currentItem
        var states=[String]();manager.onState={state,message in states.append(state+": "+message)}
        try manager.start(p,source:"A")
        // The production controller allows up to 8s for possible + 8s for the system
        // presentation. The old 8s assertion could fail while a valid start was pending.
        for _ in 0..<180{if manager.active || !manager.enabled{break};try await Task.sleep(nanoseconds:100_000_000)}
        XCTAssertTrue(manager.active,"Actual AVKit video window must start; states: \(states.joined(separator:" | "))")
        XCTAssertTrue(p.player.currentItem === item);XCTAssertEqual(p.token,"lifecycle-fixture")
        manager.stop();for _ in 0..<30{if !manager.enabled{break};try await Task.sleep(nanoseconds:100_000_000)}
        XCTAssertFalse(manager.enabled);XCTAssertTrue(p.player.currentItem === item);XCTAssertTrue(p.surface.videoLayer.player === p.player)
    }
}
