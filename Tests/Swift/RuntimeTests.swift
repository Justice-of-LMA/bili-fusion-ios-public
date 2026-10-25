import XCTest
import WebKit
import AVFoundation
@testable import Fusion

final class RuntimeTests: XCTestCase {
    @MainActor func testConcurrentHTTPInitializationResumesEveryCaller() async {
        let client = HTTP(), finished = expectation(description:"Every concurrent request completes")
        finished.expectedFulfillmentCount = 24
        // Closed loopback port: no external request or user account involved.
        for _ in 0..<24 {
            Task.detached {
                defer { finished.fulfill() }
                _ = try? await client.fetch(URLRequest(url:URL(string:"http://127.0.0.1:9/fusion-test")!))
            }
        }
        await fulfillment(of:[finished],timeout:15)
    }
    @MainActor private func appWeb() throws -> WKWebView {
        let delegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let root = try XCTUnwrap(delegate.window?.rootViewController)
        root.loadViewIfNeeded()
        return try XCTUnwrap(root.view.subviews.compactMap { $0 as? WKWebView }.first)
    }
    @MainActor private func waitFor(_ web: WKWebView, _ script: String) async throws {
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript(script)) as? Bool == true { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("WKWebView condition timed out: \(script)")
        throw FusionError("Web runtime test timed out")
    }
    @MainActor func testBundledWebFullscreenControlsAndBridge() async throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String,VoiceSegment.aiEnabled ? "0.3.2" : "0.2.5")
        let web = try appWeb()
        try await waitFor(web, "typeof receiveNative === 'function' && !!document.getElementById('full')")
        let title = try await web.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(title, "二路随行")
        // Native bridge is exercised by the real WK custom-origin main frame.
        _ = try await web.evaluateJavaScript("document.getElementById('full').click(); true")
        try await waitFor(web, "document.body.classList.contains('full')")
        let hit = try await web.evaluateJavaScript("(()=>{let b=document.getElementById('settingsToggle'),r=b.getBoundingClientRect();return document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)===b})()") as? Bool
        XCTAssertEqual(hit, true)
        _ = try await web.evaluateJavaScript("document.getElementById('settingsToggle').click(); true")
        try await waitFor(web, "!document.getElementById('settings').hidden")
        _ = try await web.evaluateJavaScript("document.getElementById('settingsClose').click(); document.getElementById('dual').click(); true")
        try await waitFor(web, "document.body.classList.contains('dual')")
        let target = try await web.evaluateJavaScript("document.getElementById('target').value") as? String
        XCTAssertEqual(target, "B")
        let maxDelay = try await web.evaluateJavaScript("document.getElementById('delayA').max") as? String
        XCTAssertEqual(maxDelay, "20")
        let transparent = try await web.evaluateJavaScript("getComputedStyle(document.getElementById('stage')).backgroundColor") as? String
        XCTAssertEqual(transparent, "rgba(0, 0, 0, 0)")
        let before = web.window?.rootViewController?.prefersStatusBarHidden
        XCTAssertEqual(before, true)
        _ = try await web.evaluateJavaScript("document.getElementById('dual').click(); document.getElementById('full').click(); true")
        try await waitFor(web, "!document.body.classList.contains('full')")
        // Fetch the local attribution via the production scheme handler.
        _ = try await web.evaluateJavaScript("fetch('NOTICES.txt').then(r=>r.text()).then(t=>window.__noticeOK=t.length>20).catch(()=>window.__noticeOK=false); true")
        try await waitFor(web, "window.__noticeOK===true")
    }
    @MainActor func testChatAreaMatchesAViewportThroughLayoutSwitches() async throws {
        let web = try appWeb()
        try await waitFor(web, "window.__fusionUIReady===true")
        // Exercise the actual WKWebView percentage geometry, not a reimplementation in Swift.
        for mode in 0..<4 {
            _ = try await web.evaluateJavaScript("(()=>{const full=\(mode>=2),dual=\(mode%2==1);if(document.body.classList.contains('full')!==full)document.getElementById('full').click();if(document.body.classList.contains('dual')!==dual)document.getElementById('dual').click();return true})()")
            for area in [25, 50, 75, 100] {
                _ = try await web.evaluateJavaScript("(()=>{const e=document.getElementById('chatArea');e.value='\(area)';e.dispatchEvent(new Event('input'));const n=document.getElementById('maxRows');n.value='11';n.dispatchEvent(new Event('input'));return true})()")
                try await waitFor(web, "(()=>{const a=document.getElementById('viewA').getBoundingClientRect(),b=document.getElementById('bullets').getBoundingClientRect();return a.height>0&&Math.abs(b.height-a.height*\(Double(area)/100))<0.1&&Math.abs(a.top-b.top)<0.1&&Math.abs(a.width-b.width)<0.1})()")
                for enabled in [false, true] {
                    _ = try await web.evaluateJavaScript("(()=>{const e=document.getElementById('chatA');e.checked=\(enabled);e.dispatchEvent(new Event('input'));return true})()")
                    let same = try await web.evaluateJavaScript("(()=>{const a=document.getElementById('viewA').getBoundingClientRect(),b=document.getElementById('bullets').getBoundingClientRect();return Math.abs(b.height-a.height*\(Double(area)/100))<0.1})()") as? Bool
                    XCTAssertEqual(same, true)
                }
            }
        }
        _ = try await web.evaluateJavaScript("(()=>{if(document.body.classList.contains('full'))document.getElementById('full').click();if(document.body.classList.contains('dual'))document.getElementById('dual').click();for(const [id,value] of Object.entries({chatArea:'50',maxRows:'8'})){const e=document.getElementById(id);e.value=value;e.dispatchEvent(new Event('input'));}return true})()")
    }
    @MainActor func testScrollSpeedSettingPersistsAcrossFullscreen() async throws {
        let web=try appWeb();try await waitFor(web,"window.__fusionUIReady===true")
        let result=try await web.evaluateJavaScript("""
        (()=>{const s=document.getElementById('chatSpeed'),old=s.value,saved=localStorage.getItem('fusion-mobile-v1');
        try{s.value='.5';s.dispatchEvent(new Event('input'));const a=document.getElementById('chatSpeedValue').textContent==='0.5 倍'&&JSON.parse(localStorage.getItem('fusion-mobile-v1')).chatSpeed==='0.5';
        s.value='2';s.dispatchEvent(new Event('input'));document.getElementById('full').click();document.getElementById('full').click();
        return a&&s.value==='2'&&document.getElementById('chatSpeedValue').textContent==='2.0 倍';
        }finally{s.value=old;s.dispatchEvent(new Event('input'));if(saved===null)localStorage.removeItem('fusion-mobile-v1');else localStorage.setItem('fusion-mobile-v1',saved)}})()
        """) as? Bool
        XCTAssertEqual(result,true)
    }
    @MainActor func testWeChatQRCodeOnlyViewport() async throws {
        let web = try appWeb()
        try await waitFor(web, "!!document.getElementById('donate')")
        _ = try await web.evaluateJavaScript("document.getElementById('donate').click(); true")
        try await waitFor(web, "document.getElementById('donationWechatPanel').hidden && !document.getElementById('donationMethods').hidden")
        _ = try await web.evaluateJavaScript("document.getElementById('donationWechat').click(); true")
        try await waitFor(web, "document.querySelector('.wechat-qr img').naturalWidth===1279")
        let clipped = try await web.evaluateJavaScript("(()=>{const e=document.querySelector('.wechat-qr'),r=e.getBoundingClientRect(),img=e.querySelector('img'),s=img.getBoundingClientRect(),k=img.naturalWidth/s.width;return r.width>200 && Math.abs(r.width-r.height)<1 && getComputedStyle(e).overflow==='hidden' && Math.abs((r.x-s.x)*k-312)<1 && Math.abs((r.y-s.y)*k-396)<1 && Math.abs((r.bottom-s.y)*k-1050)<1})()") as? Bool
        XCTAssertEqual(clipped, true)
        _ = try await web.evaluateJavaScript("document.getElementById('donationBack').click(); true")
        try await waitFor(web, "document.getElementById('donationWechatPanel').hidden")
        _ = try await web.evaluateJavaScript("document.getElementById('donationClose').click(); true")
    }
    @MainActor func testHomeRendersBeforeAnyMediaServiceStarts() async throws {
        let delegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let window = try XCTUnwrap(delegate.window)
        XCTAssertNotNil(window.windowScene, "Use the iPad scene window, not UIScreen.main.")
        let controller = try XCTUnwrap(window.rootViewController as? FusionController)
        let web = try appWeb()
        try await waitFor(web, "window.__fusionUIReady === true")
        XCTAssertFalse(controller.isMediaProxyRunning, "Opening the home page must not wait for loopback networking.")
        XCTAssertGreaterThan(web.bounds.width, 200)
        XCTAssertGreaterThan(web.bounds.height, 160)
        let overlay = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? StartupOverlay }.first)
        for _ in 0..<30 {
            if overlay.isHidden { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(overlay.isHidden)
        let visible = try await web.evaluateJavaScript("(()=>{const b=document.getElementById('login'),r=b.getBoundingClientRect();return r.width>0 && r.height>0 && document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)===b})()") as? Bool
        XCTAssertEqual(visible, true)
    }
    @MainActor func testMissingResourcesShowNativeRetryInsteadOfBlankScreen() async throws {
        let delegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let root = try XCTUnwrap(delegate.window?.rootViewController)
        let failed = FusionController(assets: WebAssets(root: nil))
        root.addChild(failed); failed.view.frame = root.view.bounds
        root.view.addSubview(failed.view); failed.didMove(toParent: root)
        defer { failed.willMove(toParent: nil); failed.view.removeFromSuperview(); failed.removeFromParent() }
        let overlay = try XCTUnwrap(failed.view.subviews.compactMap { $0 as? StartupOverlay }.first)
        for _ in 0..<100 {
            if !overlay.retry.isHidden { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(overlay.isHidden)
        XCTAssertFalse(overlay.retry.isHidden)
        XCTAssertGreaterThan(overlay.bounds.height, 160)
        XCTAssertFalse(failed.isMediaProxyRunning)
        let labels = overlay.subviews.compactMap { $0 as? UIStackView }.flatMap { $0.arrangedSubviews }.compactMap { $0 as? UILabel }
        XCTAssertTrue(labels.contains { $0.text?.contains("Web 首页目录") == true }, "WebKit must preserve the specific safe asset diagnostic.")
        overlay.retry.sendActions(for: .touchUpInside)
        for _ in 0..<100 {
            if !overlay.retry.isHidden { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(overlay.retry.isHidden, "Failed retry must recover to a visible button.")
    }
    @MainActor func testRelocatedAliasedBundleLoadsActualHomeAndControls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("relocated-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let relocated = directory.appendingPathComponent("Re Signed.app/Web", isDirectory: true)
        try FileManager.default.createDirectory(at: relocated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: XCTUnwrap(WebAssetStore.bundledRoot), to: relocated)
        let alias = directory.appendingPathComponent("WebAlias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: relocated)
        let delegate = try XCTUnwrap(UIApplication.shared.delegate as? AppDelegate)
        let root = try XCTUnwrap(delegate.window?.rootViewController)
        let controller = FusionController(assets: WebAssets(root: URL(string: alias.absoluteString + "./")!))
        root.addChild(controller); controller.view.frame = root.view.bounds
        root.view.addSubview(controller.view); controller.didMove(toParent: root)
        defer { controller.willMove(toParent: nil); controller.view.removeFromSuperview(); controller.removeFromParent() }
        let web = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? WKWebView }.first)
        try await waitFor(web, "window.__fusionUIReady===true && typeof receiveNative==='function'")
        let overlay = try XCTUnwrap(controller.view.subviews.compactMap { $0 as? StartupOverlay }.first)
        for _ in 0..<30 {
            if overlay.isHidden { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(overlay.isHidden, "Relocated resources must render, not just return bytes.")
        XCTAssertFalse(controller.isMediaProxyRunning)
        let hit = try await web.evaluateJavaScript("(()=>{let b=document.getElementById('login'),r=b.getBoundingClientRect();return r.width>0 && document.elementFromPoint(r.x+r.width/2,r.y+r.height/2)===b})()") as? Bool
        XCTAssertEqual(hit, true)
        _ = try await web.evaluateJavaScript("document.getElementById('settingsToggle').click(); true")
        try await waitFor(web, "!document.getElementById('settings').hidden")
    }
    @MainActor func testConcurrentProxyStartsShareListenerAndStopCancelsWaiters() async throws {
        let proxy = MediaProxy(); defer { proxy.stop() }
        async let first: Void = proxy.start()
        async let second: Void = proxy.start()
        _ = try await (first, second)
        XCTAssertTrue(proxy.isRunning)
        let a = try proxy.register(URL(string: "https://test.bilivideo.com/a.m3u8")!)
        try await proxy.start()
        let b = try proxy.register(URL(string: "https://test.bilivideo.com/b.m3u8")!)
        XCTAssertEqual(a.port, b.port)
        proxy.stop(); XCTAssertFalse(proxy.isRunning)
        let pending = Task { try await proxy.start() }
        await Task.yield()
        proxy.stop()
        // Either ready won the race or cancellation did; neither branch may hang.
        do { try await pending.value } catch { XCTAssertFalse(proxy.isRunning) }
    }
    @MainActor func testLoopbackCapabilityAndPlaylistRewrite() async throws {
        let proxy = MediaProxy(); try await proxy.start(); defer { proxy.stop() }
        let remote = URL(string:"https://test.bilivideo.com/live/index.m3u8")!
        let local = try proxy.register(remote)
        XCTAssertEqual(local.host,"127.0.0.1")
        XCTAssertEqual(local, try proxy.register(remote))
        let playlist = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:2,\nsegment.ts\n"
        let rewritten = try proxy.rewrite(playlist,base:remote)
        XCTAssertFalse(rewritten.contains("key.bin")); XCTAssertFalse(rewritten.contains("segment.ts"))
        XCTAssertEqual(rewritten.components(separatedBy:"http://127.0.0.1:").count-1,3)
        XCTAssertThrowsError(try proxy.rewrite("#EXTM3U\nhttps://evil.test/file.ts",base:remote))
        let forbidden = local.deletingLastPathComponent().appendingPathComponent("not-registered")
        let (_, response) = try await URLSession.shared.data(from:forbidden)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,404)
    }

    @MainActor func testManagedMediaSourcePlaybackPathForPlatformFLV() async throws {
        let web=try appWeb();try await waitFor(web,"window.__fusionUIReady===true")
        let supported=try await web.evaluateJavaScript("window.mpegts?.isSupported()===true") as? Bool;XCTAssertEqual(supported,true)
        let dir=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"Fixtures",withExtension:nil))
        var bytes=try Data(contentsOf:dir.appendingPathComponent("init.mp4"))
        for i in 0..<3{bytes.append(try Data(contentsOf:dir.appendingPathComponent("segment-\(i).m4s")))}
        let encoded=bytes.base64EncodedString()
        _ = try await web.evaluateJavaScript("""
        (()=>{const M=window.ManagedMediaSource||window.MediaSource,v=document.createElement('video');v.id='platform-mse-fixture';v.playsInline=true;v.muted=true;v.disableRemotePlayback=true;v.style.cssText='position:fixed;left:-1500px;width:320px;height:180px';document.body.append(v);const m=new M();window.__platformMSE=m;v.src=URL.createObjectURL(m);m.addEventListener('sourceopen',()=>{try{const s=m.addSourceBuffer('video/mp4; codecs="avc1.42001E,mp4a.40.2"');s.addEventListener('updateend',()=>{try{m.endOfStream()}catch{}});s.appendBuffer(Uint8Array.from(atob('\(encoded)'),c=>c.charCodeAt(0)));}catch(e){window.__platformMSEError=String(e)}});v.play().catch(e=>window.__platformMSEError=String(e));return true})()
        """)
        defer{web.evaluateJavaScript("(()=>{const v=document.getElementById('platform-mse-fixture');if(v){v.pause();URL.revokeObjectURL(v.src);v.remove()}window.__platformMSE=null})()",completionHandler:nil)}
        try await waitFor(web,"(()=>{const v=document.getElementById('platform-mse-fixture');return v?.videoWidth>0&&v.currentTime>.2})()")
        let error=try await web.evaluateJavaScript("window.__platformMSEError||''") as? String;XCTAssertEqual(error,"")
    }

    @MainActor func testWebVoiceFallbackProcessesStereoAndBypassesMono() async throws {
        let web=try appWeb();try await waitFor(web,"window.__fusionUIReady===true")
        let file=try XCTUnwrap(Bundle.main.url(forResource:"voice-reducer",withExtension:"js",subdirectory:"Web"))
        let code=try String(contentsOf:file,encoding:.utf8).replacingOccurrences(of:"})(globalThis);",with:"})(window.__voiceTestRoot);")
        _ = try await web.evaluateJavaScript("window.__voiceTestRoot={isSecureContext:false}; true")
        _ = try await web.evaluateJavaScript(code)
        _ = try await web.evaluateJavaScript("""
        (async()=>{try{const all=[];for(const mode of ['centre','side','mono','unknown','off']){
        const n=mode==='mono'?1:2,c=new OfflineAudioContext(n,48000,48000),b=c.createBuffer(n,48000,48000);
        for(let k=0;k<n;k++){const d=b.getChannelData(k);for(let i=0;i<d.length;i++)d[i]=.2*Math.sin(2*Math.PI*1000*i/48000)*(mode==='side'&&k===1?-1:1)}
        const s=c.createBufferSource();s.buffer=b;c.createMediaElementSource=()=>s;c.resume=async()=>{};
        window.__voiceTestRoot.AudioContext=function(){return c};const r=new window.__voiceTestRoot.FusionVoiceReducer({});
        r.setChannels(mode==='unknown'?0:n);await r.set(true,1);if(mode==='off')await r.set(false,1);
        s.start();const audio=await c.startRendering();let input=0,output=0,error=0;
        for(let i=12000;i<audio.length;i++){const x=b.getChannelData(0)[i],y=audio.getChannelData(0)[i];input+=x*x;output+=y*y;error=Math.max(error,Math.abs(x-y))}
        all.push({mode,ratio:Math.sqrt(output/input),error,graph:!!r.remove});}window.__voiceGraphResult=all;
        }catch(e){window.__voiceGraphError=String(e)}finally{window.__voiceGraphDone=true}})();true
        """)
        try await waitFor(web,"window.__voiceGraphDone===true")
        let error=try await web.evaluateJavaScript("window.__voiceGraphError||''") as? String
        XCTAssertEqual(error,"")
        let result=try await web.evaluateJavaScript("window.__voiceGraphResult")
        let values=try XCTUnwrap(result as? [[String:Any]])
        XCTAssertEqual(values.count,5)
        for value in values {
            XCTAssertEqual(value["graph"] as? Bool,true)
            if value["mode"] as? String == "centre" {XCTAssertLessThan(value["ratio"] as? Double ?? 1,0.3)}
            else {XCTAssertLessThan(value["error"] as? Double ?? 1,0.000001)}
        }
    }

    @MainActor func testEncodedMediaAudioOnlyAndSeek() async throws {
        // Test pattern + silent AAC generated by our own fixture tool, not public live content.
        let dir = try XCTUnwrap(Bundle(for: Self.self).url(forResource:"Fixtures",withExtension:nil))
        var data = try Data(contentsOf:dir.appendingPathComponent("init.mp4"))
        for i in 0..<24 { data.append(try Data(contentsOf:dir.appendingPathComponent("segment-\(i).m4s"))) }
        let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".mp4")
        try data.write(to:local); defer { try? FileManager.default.removeItem(at:local) }
        let a = NativePlayer(), b = NativePlayer(); defer { a.close(); b.close() }
        a.open(url:local,token:"test-A",volume:0.25); b.open(url:local,token:"test-B",volume:0,audioOnly:true)
        a.player.isMuted = true; b.player.isMuted = true; a.play(); b.play()
        for _ in 0..<100 {
            if a.player.currentTime().seconds>4 && b.player.currentTime().seconds>4 { break }
            try await Task.sleep(nanoseconds:200_000_000)
        }
        XCTAssertGreaterThan(a.player.currentTime().seconds,4)
        XCTAssertGreaterThan(b.player.currentTime().seconds,4)
        XCTAssertEqual(a.player.volume,0.25); XCTAssertEqual(b.player.volume,0)
        let tracks = try XCTUnwrap(b.player.currentItem).tracks
        XCTAssertTrue(tracks.contains { $0.assetTrack?.mediaType == .video })
        XCTAssertTrue(tracks.filter { $0.assetTrack?.mediaType == .video }.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(tracks.contains { $0.assetTrack?.mediaType == .audio && $0.isEnabled })
        let item = b.player.currentItem; b.setAudioOnly(false)
        XCTAssertTrue(b.player.currentItem === item)
        XCTAssertTrue(tracks.filter { $0.assetTrack?.mediaType == .video }.allSatisfy { $0.isEnabled })
        a.pause(); try await a.seek(1)
        for _ in 0..<30 { if a.snapshot()["seeking"] as? Bool == false { break }; try await Task.sleep(nanoseconds:100_000_000) }
        XCTAssertEqual(a.player.currentTime().seconds,1,accuracy:0.25)
        a.play(); try await Task.sleep(nanoseconds:1_500_000_000)
        XCTAssertGreaterThan(a.player.currentTime().seconds,1.7)
    }
}
