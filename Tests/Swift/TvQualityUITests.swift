import XCTest
import WebKit
@testable import Fusion

/// Bundled control UI in real WebKit, with an offline paired-TV fixture.
final class TvQualityUITests: XCTestCase {
    @MainActor private func waitFor(_ web: WKWebView, _ script: String) async throws {
        for _ in 0..<60 {
            if (try? await web.evaluateJavaScript(script)) as? Bool == true { return }
            try await Task.sleep(nanoseconds:50_000_000)
        }
        XCTFail("TV UI condition did not settle: \(script)")
        throw FusionError("TV UI fixture timeout")
    }
    @MainActor private func fixture(quality: Bool = true, scLifetime: Bool = false) async throws -> WKWebView {
        let configuration=WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
        let web=WKWebView(frame:CGRect(x:0,y:0,width:390,height:844),configuration:configuration)
        web.loadHTMLString("<html><body><header></header><div class='setup'></div><div class='stage-tools'></div><input id='qualityA' value='10000'><input id='qualityB' value='0'><input id='qualityC' value='80'></body></html>",baseURL:nil)
        try await waitFor(web,"document.readyState==='complete' && !!document.getElementById('qualityA')")
        for resource in ["core","sc-lifetime-ui","tv-control"] {
            let url=try XCTUnwrap(Bundle.main.url(forResource:resource,withExtension:"js",subdirectory:"Web"))
            _ = try await web.evaluateJavaScript(try String(contentsOf:url,encoding:.utf8)+";true")
        }
        _ = try await web.evaluateJavaScript("""
        window.requests=[];
        window.FusionSCLifetime={get:()=>FusionCore.scLifetime({mode:"uniform",uniformSeconds:120})};
        window.tvState={ok:true,scLifetimeControl:\(scLifetime ? "1":"0"),qualityControl:\(quality ? "1":"0"),casting:true,rooms:['A','B','C'].map((source,i)=>({source,room:String(i+6),enabled:true,video:i===0,volume:50,delay:0,quality:0,currentQuality:400,qualityLabel:'1080P',qualityBusy:false,qualityStatus:'已应用',qualities:[{qn:400,label:'1080P'},{qn:10000,label:'原画'}]})),settings:{}};
        window.FusionShare={encode:()=> 'offline-fixture'};
        FusionTV.mount({read:()=>[{enabled:true}],preview:()=>{},restore:()=>{},rpc:async(op,a)=>{
          if(op!=='tvRequest')return {};
          requests.push(JSON.parse(JSON.stringify(a)));
          if(a.action==='pair')return {protocol:1,token:'a'.repeat(32)};
          if(a.action==='config'&&a.data.settings)tvState.settings={...tvState.settings,...a.data.settings};
          if(a.action==='settings')tvState.settings={...tvState.settings,...a.data};
          if(a.action==='control'&&a.data.action==='quality'){
            const lane=tvState.rooms.find(x=>x.source===a.data.source);
            lane.quality=a.data.value;lane.qualityBusy=true;lane.qualityStatus='正在准备新画质';
          }
          return JSON.parse(JSON.stringify(tvState));
        }});
        document.querySelector('[data-address]').value='192.168.1.8:18762';
        document.querySelector('[data-pin]').value='123456';
        document.querySelector('[data-pair]').click();true
        """)
        try await waitFor(web,"requests.some(r=>r.action==='config') && !document.querySelector('[data-start]').disabled")
        return web
    }
    @MainActor func testTVQualityUsesTelevisionChoicesAndDoesNotRefreshOtherStreams() async throws {
        let web=try await fixture();defer{web.stopLoading()}
        let initial=try await web.evaluateJavaScript("""
        (()=>{const config=requests.find(r=>r.action==='config');return JSON.stringify(config.data.qualities)==='[10000,0,80]'&&document.querySelector('[data-tv-quality=A]').options.length===3&&document.querySelector('[data-tv-quality-state=B]').textContent.includes('当前实际：1080P')})()
        """) as? Bool
        XCTAssertEqual(initial,true)
        _ = try await web.evaluateJavaScript("const q=document.querySelector('[data-tv-quality=B]');q.value='10000';q.dispatchEvent(new Event('change'));true")
        try await waitFor(web,"document.querySelector('[data-tv-quality=B]').disabled")
        let changed=try await web.evaluateJavaScript("""
        (()=>{const controls=requests.filter(r=>r.action==='control');return controls.length===1&&JSON.stringify(controls[0].data)==='{"action":"quality","source":"B","value":10000}'&&!document.querySelector('[data-tv-quality=A]').disabled&&document.querySelector('[data-tv-quality-state=B]').textContent.includes('当前实际：1080P')&&document.querySelector('[data-tv-quality-state=B]').textContent.includes('正在准备')&&document.querySelectorAll('.tv-lane')[1].textContent.includes('仍仅播放音频')})()
        """) as? Bool
        XCTAssertEqual(changed,true)
        let count=try await web.evaluateJavaScript("requests.length") as? Int
        try await Task.sleep(nanoseconds:500_000_000)
        let after=try await web.evaluateJavaScript("requests.length") as? Int
        XCTAssertEqual(count,after,"No polling, automatic refresh or hidden resubmission")
    }
    @MainActor func testOldTelevisionGetsNoUnsupportedQualityCommands() async throws {
        let web=try await fixture(quality:false);defer{web.stopLoading()}
        let result=try await web.evaluateJavaScript("""
        (()=>{const config=requests.find(r=>r.action==='config');return !Object.hasOwn(config.data.settings,'scLifetime')&&!Object.hasOwn(config.data,'qualities')&&!document.querySelector('[data-tv-quality]')&&document.querySelector('[data-status]').textContent.includes('不支持手机调画质')&&requests.every(r=>r.action!=='control')})()
        """) as? Bool
        XCTAssertEqual(result,true)
    }
    @MainActor func testTVSCLifetimeSyncAndRemoteEditorOnlyChangeFutureMessageRule() async throws {
        let web=try await fixture(scLifetime:true);defer{web.stopLoading()}
        let initial=try await web.evaluateJavaScript("""
        (()=>{const config=requests.find(r=>r.action==='config');return config.data.settings.scLifetime.mode==='uniform'&&config.data.settings.scLifetime.uniformSeconds===120&&!document.querySelector('[data-sc-lifetime]').hidden&&document.querySelector('[data-sc-seconds]').value==='120'})()
        """) as? Bool
        XCTAssertEqual(initial,true)
        _ = try await web.evaluateJavaScript("document.querySelector('[data-sc-seconds]').value='45';document.querySelector('[data-sc-apply]').click();true")
        try await waitFor(web,"requests.some(r=>r.action==='settings')&&!document.querySelector('[data-sc-apply]').disabled")
        let changed=try await web.evaluateJavaScript("""
        (()=>{const settings=requests.filter(r=>r.action==='settings');return settings.length===1&&Object.keys(settings[0].data).join()==='scLifetime'&&settings[0].data.scLifetime.uniformSeconds===45&&requests.filter(r=>r.action==='config').length===1&&requests.every(r=>r.action!=='control')})()
        """) as? Bool
        XCTAssertEqual(changed,true)
    }
    @MainActor func testQualityCapableOldTVDoesNotReceiveNewSCLifetimeField() async throws {
        let web=try await fixture(quality:true,scLifetime:false);defer{web.stopLoading()}
        let result=try await web.evaluateJavaScript("""
        (()=>{const config=requests.find(r=>r.action==='config');return Object.hasOwn(config.data,'qualities')&&!Object.hasOwn(config.data.settings,'scLifetime')&&document.querySelector('[data-sc-lifetime]').hidden&&requests.every(r=>r.action!=='settings')})()
        """) as? Bool
        XCTAssertEqual(result,true)
    }

}
