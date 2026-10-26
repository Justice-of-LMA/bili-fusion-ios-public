import XCTest
import UIKit
import WebKit
import AVFoundation
import CoreVideo
@testable import Fusion

/// Explicit opt-in live soak. Optional user-scanned login is temporary; never posts chat or records video.
final class LivePlaybackSoakTests:XCTestCase {
    @MainActor func test7777And6ContinueForFiveMinutesWithoutRefresh()async throws{
        guard ProcessInfo.processInfo.environment["FUSION_LIVE_SOAK"]=="1" else{throw XCTSkip("Live soak is opt-in; local fixtures are not a live-room verification")}
        executionTimeAllowance=900
        let loginRequested=ProcessInfo.processInfo.environment["FUSION_LIVE_LOGIN"]=="1"
        let delegate=try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let controller=try XCTUnwrap(delegate.window?.rootViewController as? FusionController)
        controller.loadViewIfNeeded()
        let web=try XCTUnwrap(controller.view.subviews.compactMap{$0 as? WKWebView}.first)
        let document=try XCTUnwrap(FileManager.default.urls(for:.documentDirectory,in:.userDomainMask).first)
        let folder=document.appendingPathComponent("live-soak",isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        func write(_ name:String,_ value:JSON)throws{
            let data=try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:folder.appendingPathComponent(name),options:.atomic)
        }
        var uiReady=false
        for _ in 0..<240{
            if (try? await web.evaluateJavaScript("window.__fusionUIReady===true && location.protocol==='fusion:'")) as? Bool == true{uiReady=true;break}
            try await Task.sleep(nanoseconds:250_000_000)
        }
        guard uiReady else{
            try write("summary.json",["inputRooms":["A":"7777","B":"6"],"aiEdition":VoiceSegment.aiEnabled,"completed":false,"failure":"Bundled page was not ready; real streams were not started","samples":[]])
            XCTFail("Bundled UI did not become ready before the live test; do not access opaque-origin storage or call this a stream failure")
            return
        }
        if loginRequested{
            do{try await LiveTestLogin.authenticate(folder:document.appendingPathComponent("live-login",isDirectory:true))}
            catch{await LiveTestLogin.clear();throw error}
        }
        let old=try await web.evaluateJavaScript("localStorage.getItem('fusion-mobile-v1')")
        let saved=String(data:try JSONSerialization.data(withJSONObject:[old]),encoding:.utf8)!
        let mirror=Mirror(reflecting:controller)
        let players=try XCTUnwrap(mirror.children.first{$0.label=="players"}?.value as? [String:NativePlayer])
        let proxy=try XCTUnwrap(mirror.children.first{$0.label=="proxy"}?.value as? MediaProxy)
        let proxyWasRunning=proxy.isRunning
        func itemErrors(_ p:NativePlayer)->[JSON]{
            (p.player.currentItem?.errorLog()?.events ?? []).suffix(3).map{event->JSON in
                let comment=(event.errorComment ?? "").replacingOccurrences(of:"https?://[^ \\n]+",with:"[media URL omitted]",options:.regularExpression)
                return ["code":event.errorStatusCode,"domain":event.errorDomain,"comment":String(comment.prefix(240))]
            }
        }
        var warmupSamples=[JSON]()
        // User accepted occasional ~10s self-recovering buffering on 2026-10-26.
        // One extra second covers the 1Hz sampler; all raw pauses remain in the report.
        let acceptedNoProgressSeconds=11.0
        var started=false
        var records=[JSON](),report:JSON=["inputRooms":["A":"7777","B":"6"],"aiEdition":VoiceSegment.aiEnabled,"requestedSeconds":300,"acceptedNoProgressSeconds":acceptedNoProgressSeconds,"authenticated":loginRequested,"completed":false]
        func cleanup()async{
            _=try? await web.evaluateJavaScript("""
            document.getElementById('stop').click();
            if(window.__liveSoakOriginalCall){Native.call=window.__liveSoakOriginalCall;delete window.__liveSoakOriginalCall;}
            (()=>{const old=\(saved)[0];if(old===null)localStorage.removeItem('fusion-mobile-v1');else localStorage.setItem('fusion-mobile-v1',old)})();true
            """)
            // Rebuild the local UI from restored preferences before another XCTest runs.
            // This reloads only bundled assets, never a room, stream, account or chat send.
            players.values.forEach{$0.close()};if !proxyWasRunning{proxy.stop()}
            if loginRequested{await LiveTestLogin.clear()}
            web.reload()
            for _ in 0..<100{
                if !web.isLoading,(try? await web.evaluateJavaScript("window.__fusionUIReady===true")) as? Bool == true{break}
                try? await Task.sleep(nanoseconds:100_000_000)
            }
        }
        defer{
            report["samples"]=records;try? write("summary.json",report)
            try? write("active.json",["active":false,"completed":report["completed"] as? Bool ?? false])
        }
        do{
        _=try await web.evaluateJavaScript("""
        document.getElementById('stop').click();
        window.__liveSoakOps=[];window.__liveSoakOriginalCall=Native.call;
        Native.call=(id,op,payload)=>{if(['resolve','mediaOpen','mediaSeek','startChat','mediaPlay','mediaPause','mediaAudioOnly'].includes(op)){const a=JSON.parse(payload);__liveSoakOps.push({op,source:a.source||null,quality:a.quality??null,at:performance.now(),trace:op===\'mediaPause\'?new Error().stack:null});}__liveSoakOriginalCall(id,op,payload);};
        for(const s of ['A','B']){
          const p=document.getElementById('platform'+s);p.value='bilibili';p.dispatchEvent(new Event('input'));
          const room=document.getElementById('room'+s);room.value=s==='A'?'7777':'6';room.dispatchEvent(new Event('input'));
          const volume=document.getElementById('volume'+s);volume.value='50';volume.dispatchEvent(new Event('input'));
          const delay=document.getElementById('delay'+s);delay.value='0';delay.dispatchEvent(new Event('change'));
        }
        document.getElementById('audioOnlyB').checked=false;document.getElementById('audioOnlyB').dispatchEvent(new Event('input'));
        const voice=document.getElementById('voiceA');voice.checked=\(VoiceSegment.aiEnabled);document.getElementById('voiceStrength').value='100';voice.dispatchEvent(new Event('input'));
        document.getElementById('connect').click();true
        """)
        let warmup=Date()
        while Date().timeIntervalSince(warmup)<65{
            if warmupSamples.count<Int(Date().timeIntervalSince(warmup))+1{
                warmupSamples.append(["elapsed":Date().timeIntervalSince(warmup),"lifecycle":controller.lifecycleState(),"itemErrors":players.mapValues{itemErrors($0)}])
            }
            if ["A","B"].allSatisfy({s in guard let p=players[s] else{return false};return p.player.timeControlStatus == .playing && p.player.currentTime().seconds>0.2 && !p.token.isEmpty}){started=true;break}
            try await Task.sleep(nanoseconds:250_000_000)
        }
        guard started else{
            report["failure"]="Both public rooms did not reach real native playback"
            report["warmup"]=warmupSamples
            report["operations"]=(try? await web.evaluateJavaScript("window.__liveSoakOps")) ?? []
            report["finalLifecycle"]=controller.lifecycleState()
            report["uiStatus"]=(try? await web.evaluateJavaScript("['statusA','statusB','notice'].map(id=>document.getElementById(id)?.textContent||'').join(' | ')")) ?? ""
            XCTFail("Live playback did not start; do not count API access or fixture results as five-minute verification")
            await cleanup();return
        }
        _=try await web.evaluateJavaScript("if(!document.body.classList.contains('dual'))document.getElementById('dual').click();if(!document.body.classList.contains('full'))document.getElementById('full').click();true")
        let items=try ["A","B"].map{s in try XCTUnwrap(players[s]?.player.currentItem)}
        let tokens=["A","B"].map{players[$0]!.token}
        let outputs=items.map{item->AVPlayerItemVideoOutput in
            let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA]);item.add(output);return output
        }
        defer{for i in 0..<2{items[i].remove(outputs[i])}}
        var last=["A":players["A"]!.player.currentTime().seconds,"B":players["B"]!.player.currentTime().seconds]
        var lastAdvanced=["A":0.0,"B":0.0],longest=["A":0.0,"B":0.0],progress=["A":0.0,"B":0.0],newFrames=["A":0,"B":0]
        let start=Date();var audioOnly=false
        report["warmup"]=warmupSamples
        report["warmupSeconds"]=Date().timeIntervalSince(warmup)
        try write("active.json",["active":true,"startedAt":start.timeIntervalSince1970,"rooms":["7777","6"]])
        while Date().timeIntervalSince(start)<300{
            let elapsed=Date().timeIntervalSince(start)
            if elapsed>=150 && !audioOnly{
                _=try await web.evaluateJavaScript("const e=document.getElementById('audioOnlyB');e.checked=true;e.dispatchEvent(new Event('input'));true")
                audioOnly=true
            }
            var row:JSON=["elapsed":elapsed,"bAudioOnly":audioOnly]
            for (index,source) in ["A","B"].enumerated(){
                let p=players[source]!,time=p.player.currentTime().seconds,state=p.snapshot()
                XCTAssertTrue(p.player.currentItem === items[index],"Soak must not silently replace a live item")
                XCTAssertEqual(p.token,tokens[index])
                if time.isFinite,time>(last[source] ?? time)+0.03{
                    progress[source,default:0]+=time-(last[source] ?? time);lastAdvanced[source]=elapsed
                }
                longest[source]=max(longest[source] ?? 0,elapsed-(lastAdvanced[source] ?? 0))
                last[source]=time
                let output=outputs[index],position=p.player.currentTime()
                if output.hasNewPixelBuffer(forItemTime:position),output.copyPixelBuffer(forItemTime:position,itemTimeForDisplay:nil) != nil{newFrames[source,default:0]+=1}
                let logs=items[index].accessLog()?.events ?? []
                let itemErrors=(items[index].errorLog()?.events ?? []).suffix(3).map{event->JSON in
                    let comment=(event.errorComment ?? "").replacingOccurrences(of:"https?://[^ \\n]+",with:"[media URL omitted]",options:.regularExpression)
                    return ["code":event.errorStatusCode,"domain":event.errorDomain,"comment":String(comment.prefix(240))]
                }
                row[source]=["time":time.isFinite ? time:0,"rate":state["rate"] ?? 0,"readyState":state["readyState"] ?? 0,"waiting":state["waiting"] ?? false,"paused":state["paused"] ?? true,"layerReady":p.surface.videoLayer.isReadyForDisplay,"buffer":state["loaded"] ?? [],"bytes":logs.last?.numberOfBytesTransferred ?? 0,"stalls":logs.last?.numberOfStalls ?? 0,"error":state["error"] ?? "","transportError":state["transportError"] ?? [:],"itemErrors":itemErrors,"observedBitrate":logs.last?.observedBitrate.isFinite == true ? logs.last!.observedBitrate:0,"transferSeconds":logs.last?.transferDuration.isFinite == true ? logs.last!.transferDuration:0] as JSON
            }
            records.append(row)
            try await Task.sleep(nanoseconds:1_000_000_000)
        }
        let ops=(try await web.evaluateJavaScript("window.__liveSoakOps")) as? [JSON] ?? []
        report["actualSeconds"]=Date().timeIntervalSince(start);report["progressSeconds"]=progress;report["longestNoProgressSeconds"]=longest;report["newVideoFramesSampled"]=newFrames;report["operations"]=ops;report["bAudioOnlyAfterSeconds"]=150
        report["voiceStatus"]=(try? await web.evaluateJavaScript("document.getElementById('voiceStatus').textContent")) ?? ""
        report["completed"]=true
        XCTAssertEqual(ops.filter{$0.str("op")=="resolve"}.count,2,"No automatic resolve/refresh is permitted")
        XCTAssertEqual(ops.filter{$0.str("op")=="mediaOpen"}.count,2,"No replacement players during the soak")
        XCTAssertEqual(ops.filter{$0.str("op")=="mediaSeek"}.count,0,"Do not jump to live to hide a stall")
        for s in ["A","B"]{
            XCTAssertGreaterThan(progress[s] ?? 0,270,"Playback should advance through the five-minute soak")
            XCTAssertLessThanOrEqual(longest[s] ?? 300,acceptedNoProgressSeconds,"Persistent stops still fail; user accepted about ten seconds of self-recovering buffering, not an unrecovered player")
            XCTAssertGreaterThan(newFrames[s] ?? 0,s=="A" ? 30:15,"Sample actual decoded video before switching B to audio-only")
        }
        await cleanup()
        }catch{await cleanup();throw error}
    }
}
