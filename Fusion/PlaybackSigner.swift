import Foundation
import WebKit
/// Disposable no-network Web Worker. Official signing code never sees cookies or an app bridge.
@MainActor final class PlaybackSigner: NSObject, WKNavigationDelegate {
    private var web: WKWebView?, continuation: CheckedContinuation<String,Error>?, poll: Task<Void,Never>?, timeout: Task<Void,Never>?
    private var source=""
    func sign(_ code: String, room: String) async throws -> String {
        guard continuation==nil,code.utf8.count<=250000,!code.isEmpty else { throw FusionError("取流校验忙或校验代码无效") }
        let base=Bundle.main.resourceURL!.appendingPathComponent("Web/vendor")
        let library=try String(contentsOf:base.appendingPathComponent("crypto-core.js"),encoding:.utf8)+"\n"+String(contentsOf:base.appendingPathComponent("crypto-md5.js"),encoding:.utf8)
        let args=[room,UUID().uuidString.replacingOccurrences(of:"-",with:""),String(Int(Date().timeIntervalSince1970))]
        let encoded=String(data:try JSONSerialization.data(withJSONObject:args),encoding:.utf8)!
        source=library+"\n"+code+"\npostMessage(String(ub98484234.apply(null,"+encoded+")));"
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        let web=WKWebView(frame:.zero,configuration:config);self.web=web;web.navigationDelegate=self
        return try await withCheckedThrowingContinuation { c in
            continuation=c
            web.loadHTMLString("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; worker-src blob:; connect-src 'none';\"><title>Local playback calculation</title>",baseURL:URL(string:"https://signer.invalid/"))
            timeout=Task { [weak self] in try? await Task.sleep(nanoseconds:10_000_000_000);if !Task.isCancelled { self?.finish(.failure(FusionError("平台取流校验超时，请手动再试"))) } }
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard continuation != nil, let data=try? JSONSerialization.data(withJSONObject:source,options:.fragmentsAllowed),let literal=String(data:data,encoding:.utf8) else { return }
        webView.evaluateJavaScript("(()=>{const w=new Worker(URL.createObjectURL(new Blob(["+literal+"],{type:'application/javascript'})));w.onmessage=e=>{window.answer={value:e.data};w.terminate()};w.onerror=()=>{window.answer={error:true};w.terminate()};setTimeout(()=>{w.terminate();window.answer||={error:true}},8000)})()",completionHandler:nil)
        poll=Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds:100_000_000);guard let self,!Task.isCancelled,let web=self.web else { return }
                do { let raw=try await web.evaluateJavaScript("window.answer||null");if let answer=raw as? JSON {
                    let value=answer.str("value");if answer["error"] as? Bool==true || value.isEmpty || value.count>8000 { self.finish(.failure(FusionError("平台连接校验失败"))) } else { self.finish(.success(value)) };return
                }}catch { self.finish(.failure(FusionError("取流校验页面不可用")));return }
            }
        }
    }
    private func finish(_ result: Result<String,Error>) { let c=continuation;continuation=nil;timeout?.cancel();poll?.cancel();web?.stopLoading();web?.navigationDelegate=nil;web=nil;source="";c?.resume(with:result) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(FusionError("本机取流校验未能启动"))) }
}

