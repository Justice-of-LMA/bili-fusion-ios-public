import XCTest
import WebKit
@testable import Fusion

final class NetworkResolutionTests: XCTestCase {
    @MainActor func testDefaultExplicitSelectionPersistenceAndRestore() throws {
        let name="fusion-dns-test-"+UUID().uuidString, defaults=try XCTUnwrap(UserDefaults(suiteName:name))
        defer { defaults.removePersistentDomain(forName:name) }
        var applications=[NetworkResolution.Mode]()
        let policy=NetworkResolution(defaults:defaults,apply:{ applications.append($0) })
        XCTAssertEqual(policy.mode,.system);XCTAssertTrue(applications.isEmpty)
        policy.applySaved();XCTAssertEqual(applications,[.system])
        _ = try policy.select("compatible");XCTAssertEqual(applications,[.system,.compatible])
        let restarted=NetworkResolution(defaults:defaults,apply:{ applications.append($0) })
        restarted.applySaved();XCTAssertEqual(applications,[.system,.compatible,.compatible])
        _ = try restarted.select("system");XCTAssertEqual(applications.last,.system)
        XCTAssertEqual(NetworkResolution(defaults:defaults,apply:{_ in}).mode,.system)
        XCTAssertThrowsError(try policy.select("https://unknown.invalid"))
        XCTAssertEqual(applications.count,4,"invalid values must not change resolver policy")
        XCTAssertEqual(NetworkResolution.resolverURL.scheme,"https")
        XCTAssertTrue(NetworkResolution.resolverAddresses.contains(where:{$0.contains(":")}),"IPv6 bootstrap must remain available")
        XCTAssertTrue(NetworkResolution.resolverAddresses.contains(where:{$0.contains(".")}),"IPv4 bootstrap must remain available")
    }

    func testDNSDiagnosticsNameHostAndStageWithoutSignedURLOrCredentials() {
        let url=URL(string:"https://live_test.bilivideo.com/private/path.m3u8?token=never-display&cookie=secret")!
        let error=MediaProxy.RequestFailure(underlying:URLError(.cannotFindHost),url:url,stage:"重定向后的播放列表")
        let detail=MediaProxy.networkDetail(error)
        XCTAssertTrue(detail.contains("-1003"));XCTAssertTrue(detail.contains("live_test.bilivideo.com"));XCTAssertTrue(detail.contains("重定向后的播放列表"))
        for secret in ["private","token","never-display","cookie","secret","https://"] { XCTAssertFalse(detail.contains(secret)) }
        XCTAssertTrue(MediaProxy.networkDetail(URLError(.dnsLookupFailed),url:url,stage:"FLV 直播").contains("-1006"))
        XCTAssertTrue(MediaProxy.networkDetail(URLError(.serverCertificateUntrusted),url:url,stage:"媒体片段").contains("安全连接失败"))
    }

    @MainActor func testDNSFailureNeverRetriesOrChangesURLAndManualRequestUsesSameHost() async throws {
        let original=URL(string:"https://live_test.bilivideo.com/path.m3u8?signature=fixture")!
        var requests=[URLRequest](), compatible=false
        let proxy=MediaProxy { request,_ in
            requests.append(request)
            if !compatible { throw URLError(.cannotFindHost) }
            return (Data("#EXTM3U\n".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
        }
        var request=URLRequest(url:original);request.httpMethod="GET";request.setValue("https://live.bilibili.com/",forHTTPHeaderField:"Referer")
        do { _ = try await proxy.fetchMedia(request,limit:1024);XCTFail("DNS failure must reach caller") }
        catch { XCTAssertTrue(MediaProxy.networkDetail(error).contains("-1003")) }
        XCTAssertEqual(requests.count,1,"no implicit retry or alternate CDN")
        compatible=true // An explicit user action, represented by the offline resolver fixture.
        _ = try await proxy.fetchMedia(request,limit:1024)
        XCTAssertEqual(requests.count,2);XCTAssertTrue(requests.allSatisfy{$0.url==original&&$0.httpMethod=="GET"})
        XCTAssertTrue(requests.allSatisfy{$0.value(forHTTPHeaderField:"Cookie")==nil})
    }

    @MainActor func testRedirectDNSFailureReportsFinalHostAndPreservesTLSURL() async throws {
        let first=URL(string:"https://first.bilivideo.com/a.m3u8")!, final=URL(string:"https://redirect.bilivideo.cn/b.m3u8?token=secret")!
        var urls=[URL]()
        let proxy=MediaProxy { request,_ in
            urls.append(request.url!)
            if request.url==first { return (Data(),HTTPURLResponse(url:first,statusCode:302,httpVersion:nil,headerFields:["Location":final.absoluteString])!) }
            throw URLError(.dnsLookupFailed)
        }
        var request=URLRequest(url:first);request.httpMethod="GET"
        do { _ = try await proxy.fetchMedia(request,limit:1024);XCTFail("DNS failure must reach caller") }
        catch { let text=MediaProxy.networkDetail(error);XCTAssertTrue(text.contains("redirect.bilivideo.cn"));XCTAssertTrue(text.contains("重定向后的播放列表"));XCTAssertFalse(text.contains("secret")) }
        XCTAssertEqual(urls,[first,final])
    }

    @MainActor private func waitFor(_ web:WKWebView,_ script:String) async throws {
        for _ in 0..<60 {
            if (try? await web.evaluateJavaScript(script)) as? Bool == true { return }
            try await Task.sleep(nanoseconds:50_000_000)
        }
        XCTFail("Network UI condition did not settle: \(script)");throw FusionError("Network UI fixture timeout")
    }
    @MainActor private func fixture() async throws -> WKWebView {
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        let web=WKWebView(frame:CGRect(x:0,y:0,width:390,height:844),configuration:config)
        web.loadHTMLString("<html><body><aside id='settings'></aside><main id='stage'></main></body></html>",baseURL:nil)
        try await waitFor(web,"document.readyState==='complete'&&!!document.getElementById('stage')")
        let url=try XCTUnwrap(Bundle.main.url(forResource:"network-compat",withExtension:"js",subdirectory:"Web"))
        _ = try await web.evaluateJavaScript(try String(contentsOf:url,encoding:.utf8)+";true")
        _ = try await web.evaluateJavaScript("""
        window.requests=[];window.refreshes=[];window.savedMode='system';
        window.channels={A:{room:6,quality:10000,volume:0.9,delay:2.5},B:{room:7777,quality:400,volume:0.6,delay:5.8},C:{room:616,quality:80,volume:0.4,delay:0}};
        window.originalChannels=JSON.stringify(channels);
        window.compat=FusionNetworkCompat.mount({settings:document.getElementById('settings'),stage:document.getElementById('stage'),active:s=>channels[s],rpc:async(op,args)=>{requests.push({op,args});if(op==='networkResolutionSet'){if(window.holdSetting)await new Promise(r=>window.finishSetting=r);savedMode=args.mode;}return {mode:savedMode};},refresh:async(s,c)=>{if(channels[s]===c)refreshes.push(s);}});true
        """)
        try await waitFor(web,"requests.length===1");return web
    }

    @MainActor func testDNSRecoveryIsOneManualStreamRefreshAndKeepsSettings() async throws {
        let web=try await fixture()
        _ = try await web.evaluateJavaScript("for(const s of ['A','B','C'])compat.offer(s,'直播线路域名解析失败（-1003）',channels[s]);true")
        let observed1=try await web.evaluateJavaScript("document.querySelectorAll('[data-network-recover]').length") as? Int
        XCTAssertEqual(observed1,3)
        let observed2=try await web.evaluateJavaScript("refreshes.length") as? Int
        XCTAssertEqual(observed2,0)
        _ = try await web.evaluateJavaScript("document.querySelector('[data-network-recover=B]').click();true")
        try await waitFor(web,"refreshes.length===1")
        let observed3=try await web.evaluateJavaScript("JSON.stringify(refreshes)") as? String
        XCTAssertEqual(observed3,"[\"B\"]")
        let observed4=try await web.evaluateJavaScript("requests.filter(x=>x.op==='networkResolutionSet').length") as? Int
        XCTAssertEqual(observed4,1)
        let observed5=try await web.evaluateJavaScript("JSON.stringify(channels)===originalChannels") as? Bool
        XCTAssertEqual(observed5,true)
        _ = try await web.evaluateJavaScript("const select=document.querySelector('[data-network-mode]');select.value='system';select.dispatchEvent(new Event('change'));true")
        try await waitFor(web,"savedMode==='system'&&!document.querySelector('[data-network-mode]').disabled")
        let observed6=try await web.evaluateJavaScript("refreshes.length") as? Int
        XCTAssertEqual(observed6,1,"restoring system DNS never refreshes any stream")
        web.loadHTMLString("",baseURL:nil)
    }

    @MainActor func testNonDNSErrorsAndChangedRoomsCannotTriggerRecovery() async throws {
        let web=try await fixture()
        _ = try await web.evaluateJavaScript("compat.offer('A','直播连接超时（-1001）',channels.A);compat.offer('B','安全连接失败（-1202）',channels.B);true")
        let observed7=try await web.evaluateJavaScript("document.getElementById('networkRecovery').hidden") as? Bool
        XCTAssertEqual(observed7,true)
        _ = try await web.evaluateJavaScript("compat.offer('C','直播线路域名解析失败（-1006）',channels.C);window.oldButton=document.querySelector('[data-network-recover=C]');channels.C={room:2};oldButton.click();true")
        let observed8=try await web.evaluateJavaScript("refreshes.length") as? Int
        XCTAssertEqual(observed8,0)
        let observed9=try await web.evaluateJavaScript("requests.filter(x=>x.op==='networkResolutionSet').length") as? Int
        XCTAssertEqual(observed9,0)
        web.loadHTMLString("",baseURL:nil)
    }

    @MainActor func testBatchDNSRecoveryRefreshesOnlyCurrentlyFailedRoomsOnce() async throws {
        let web=try await fixture()
        _ = try await web.evaluateJavaScript("compat.offer('A','直播线路域名解析失败（-1003）',channels.A);compat.offer('B','直播线路域名解析失败（-1006）',channels.B);document.querySelector('[data-network-recover-all]').click();true")
        try await waitFor(web,"refreshes.length===2")
        let result=try await web.evaluateJavaScript("JSON.stringify(refreshes.sort())==='[\"A\",\"B\"]'&&requests.filter(x=>x.op==='networkResolutionSet').length===1&&JSON.stringify(channels)===originalChannels") as? Bool
        XCTAssertEqual(result,true,"One explicit action refreshes each failed room once, leaving healthy C unchanged")
        try await Task.sleep(nanoseconds:200_000_000)
        let after=try await web.evaluateJavaScript("refreshes.length") as? Int
        XCTAssertEqual(after,2,"No timer or recursive retry")
        web.loadHTMLString("",baseURL:nil)
    }
    @MainActor func testRecoveredOrReopenedStreamIsNotRefreshedAfterResolverAwait() async throws {
        let web=try await fixture()
        _ = try await web.evaluateJavaScript("window.holdSetting=true;channels.A.epoch=1;channels.B.epoch=1;compat.offer('A','域名解析失败（-1003）',channels.A);compat.offer('B','域名解析失败（-1003）',channels.B);document.querySelector('[data-network-recover-all]').click();true")
        try await waitFor(web,"typeof finishSetting==='function'")
        _ = try await web.evaluateJavaScript("compat.clear('A');channels.B.epoch=2;finishSetting();true")
        try await waitFor(web,"!document.querySelector('[data-network-mode]').disabled")
        let count=try await web.evaluateJavaScript("refreshes.length") as? Int
        XCTAssertEqual(count,0,"A recovered and B changed generation while setting was pending")
        let hidden=try await web.evaluateJavaScript("document.getElementById('networkRecovery').hidden") as? Bool
        XCTAssertEqual(hidden,true,"Stale errors must not reappear")
        web.loadHTMLString("",baseURL:nil)
    }

    @MainActor func testAPIDNSFailureKeepsSafeDiagnosticsAndDoesNotRetryGETOrPOST() async throws {
        var methods=[String]()
        let api=BiliAPI(cookieStore:WKWebsiteDataStore.nonPersistent().httpCookieStore,fetch:{ request in
            methods.append(request.httpMethod ?? "GET");throw URLError(.cannotFindHost)
        })
        let url=URL(string:"https://api.live.bilibili.com/fixture?token=never-display")!
        do { _ = try await api.request(url);XCTFail("DNS failure expected") }
        catch { XCTAssertTrue(error.localizedDescription.contains("-1003"));XCTAssertTrue(error.localizedDescription.contains("api.live.bilibili.com"));XCTAssertFalse(error.localizedDescription.contains("never-display")) }
        do { _ = try await api.request(url,body:["message":"fixture"]);XCTFail("DNS failure expected") }
        catch { XCTAssertEqual((error as NSError).code,URLError.cannotFindHost.rawValue) }
        XCTAssertEqual(methods,["GET","POST"],"No request is resent")
    }

    @MainActor func testCompatibleResolverDoesNotBreakLiteralLoopbackMedia() async throws {
        let name="fusion-dns-loopback-"+UUID().uuidString, defaults=UserDefaults(suiteName:name)!
        let policy=NetworkResolution(defaults:defaults)
        _ = try policy.select("compatible")
        defer { _ = try? policy.select("system");defaults.removePersistentDomain(forName:name) }
        let proxy=MediaProxy { request,_ in
            (Data("#EXTM3U\n#EXT-X-ENDLIST\n".utf8),HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:["Content-Type":"application/vnd.apple.mpegurl"])!)
        }
        try await proxy.start();defer { proxy.stop() }
        let url=try proxy.register(URL(string:"https://fixture.bilivideo.com/a.m3u8")!)
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=5
        let session=URLSession(configuration:config);defer { session.invalidateAndCancel() }
        let (data,response)=try await session.data(from:url)
        XCTAssertEqual(url.host,"127.0.0.1");XCTAssertEqual((response as? HTTPURLResponse)?.statusCode,200)
        XCTAssertTrue(String(decoding:data,as:UTF8.self).contains("#EXTM3U"))
    }

}
