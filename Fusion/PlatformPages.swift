import UIKit
import WebKit
@MainActor final class PlatformAccountController: UIViewController, WKNavigationDelegate {
    let platform: String,source: String
    var selected: ((String)->Void)?,done:(()->Void)?
    private var web: WKWebView!,picking:Bool
    init(platform:String,source:String,picking:Bool){self.platform=platform;self.source=source;self.picking=picking;super.init(nibName:nil,bundle:nil)}
    required init?(coder:NSCoder){fatalError()}
    override func viewDidLoad(){super.viewDidLoad();title=(platform=="huya" ? "虎牙":"斗鱼")+" · 登录 / 关注"
        let config=WKWebViewConfiguration();config.websiteDataStore = .default();config.mediaTypesRequiringUserActionForPlayback = .all
        web=WKWebView(frame:.zero,configuration:config);web.customUserAgent=PlatformRoom.desktopUA;web.navigationDelegate=self;web.translatesAutoresizingMaskIntoConstraints=false;view.addSubview(web)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo:view.leadingAnchor),web.trailingAnchor.constraint(equalTo:view.trailingAnchor),web.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor),web.bottomAnchor.constraint(equalTo:view.bottomAnchor)])
        navigationItem.leftBarButtonItem=UIBarButtonItem(title:"完成",style:.done,target:self,action:#selector(finish))
        navigationItem.rightBarButtonItem=UIBarButtonItem(title:"关注选房",style:.plain,target:self,action:#selector(following))
        following()
    }
    @objc private func following(){picking=true;web.load(URLRequest(url:URL(string:platform=="huya" ? "https://www.huya.com/myfollow":"https://www.douyu.com/directory/myFollow")!))}
    @objc private func finish(){web.stopLoading();dismiss(animated:true){[weak self] in self?.done?()}}
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){
        guard action.targetFrame?.isMainFrame != false else{decisionHandler(action.request.url?.scheme=="https" ? .allow:.cancel);return}
        guard let u=action.request.url,u.scheme=="https",u.user==nil,u.password==nil,u.port==nil||u.port==443,Safety.inDomain(u.host ?? "",platform+".com") else{decisionHandler(.cancel);return}
        if picking,action.navigationType == .linkActivated,["www."+platform+".com","m."+platform+".com"].contains(u.host ?? ""),let room=try? PlatformRoom.id(platform,u.absoluteString),!["myfollow","login","user","u","g","all","download","about"].contains(room) {
            decisionHandler(.cancel);let alert=UIAlertController(title:"使用此直播间？",message:"\(platform) · \(room) → \(source)",preferredStyle:.alert)
            alert.addAction(UIAlertAction(title:"选为 "+source,style:.default){[weak self]_ in self?.selected?(room);self?.finish()});alert.addAction(UIAlertAction(title:"继续浏览",style:.cancel){_ in webView.load(URLRequest(url:u))});present(alert,animated:true);return
        };decisionHandler(.allow)
    }
}
/// Official page supplies its rendered chat. It is never refreshed or reloaded on a timer.
@MainActor final class HuyaPageChat: NSObject,ChatConnection,WKNavigationDelegate {
    private var web:WKWebView?,runner:Task<Void,Never>?
    private let room:String,sink:(JSON)->Void,host:UIView
    private var closed=false
    init(room:String,host:UIView,sink:@escaping(JSON)->Void){self.room=room;self.host=host;self.sink=sink}
    func start(){
        guard !closed else{return};let c=WKWebViewConfiguration();c.websiteDataStore = .default();c.mediaTypesRequiringUserActionForPlayback = .all
        let script=(try? String(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("Web/huya-chat-dom.js"),encoding:.utf8)) ?? ""
        c.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
        let w=WKWebView(frame:CGRect(x:-2048,y:0,width:1280,height:800),configuration:c);web=w;w.customUserAgent=PlatformRoom.desktopUA;w.navigationDelegate=self;w.isUserInteractionEnabled=false;w.accessibilityElementsHidden=true;host.addSubview(w)
        w.load(URLRequest(url:PlatformRoom.page("huya",room)));sink(["status":"正在读取虎牙官方聊天列表"])
        runner=Task{[weak self] in while !Task.isCancelled {try? await Task.sleep(nanoseconds:200_000_000);guard let self,!self.closed,let web=self.web else{return}
            guard web.url?.host=="www.huya.com",web.url?.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))==self.room else{continue}
            do{if let result=try await web.evaluateJavaScript("window.FusionHuyaList?.drain()||null") as? JSON {
                if result["ready"] as? Bool==true {self.sink(["status":"虎牙聊天列表已连接 · 收到 \(result.int("total")) 条"])}
                for m in result.arr("items"){self.sink(["packet":["cmd":"DANMU_MSG","info":[[0,1,25,m.int("color")],m.str("text"),[m.str("uid"),m.str("user")]]]])}
            }}catch{if !self.closed {self.sink(["status":"虎牙列表暂停，请手动刷新","needsRefresh":true]);self.close();return}}
        }}
    }
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void){guard let u=action.request.url else{decisionHandler(.cancel);return};decisionHandler((action.targetFrame?.isMainFrame==false && u.scheme=="https") || (u.scheme=="https"&&u.host=="www.huya.com"&&u.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))==room) ? .allow:.cancel)}
    func close(){closed=true;runner?.cancel();web?.stopLoading();web?.removeFromSuperview();web=nil}
}
@MainActor final class PlatformSender:NSObject,WKNavigationDelegate{
    private var web:WKWebView?,task:Task<Void,Never>?,continuation:CheckedContinuation<JSON,Error>?
    private var lastAttempt=Date.distantPast,committed=false
    func send(platform:String,room:String,text:String,host:UIView) async throws->JSON{
        guard continuation==nil,Date().timeIntervalSince(lastAttempt)>=5 else{throw FusionError("上一条仍在处理或发送间隔不足 5 秒")}
        let room=try PlatformRoom.id(platform,room),text=try Safety.message(text)
        let script=try String(contentsOf:Bundle.main.resourceURL!.appendingPathComponent("Web/official-chat-sender.js"),encoding:.utf8)
        let c=WKWebViewConfiguration();c.websiteDataStore = .default();c.mediaTypesRequiringUserActionForPlayback = .all
        c.userContentController.addUserScript(WKUserScript(source:script,injectionTime:.atDocumentStart,forMainFrameOnly:true))
        let w=WKWebView(frame:CGRect(x:-2048,y:0,width:1280,height:800),configuration:c);web=w;w.customUserAgent=PlatformRoom.desktopUA;w.isUserInteractionEnabled=false;w.accessibilityElementsHidden=true;host.addSubview(w)
        w.load(URLRequest(url:PlatformRoom.page(platform,room)));committed=false
        return try await withCheckedThrowingContinuation{continuation=$0
            task=Task{[weak self] in guard let self else{return};let start=Date();var commitTime=Date.distantFuture
                func literal(_ v:String)->String{String(data:try! JSONSerialization.data(withJSONObject:v,options:.fragmentsAllowed),encoding:.utf8)!}
                while !Task.isCancelled&&self.continuation != nil {
                    try? await Task.sleep(nanoseconds:350_000_000);guard !Task.isCancelled else{return}
                    if Date().timeIntervalSince(start)>45 || Date().timeIntervalSince(commitTime)>12 {self.finish(.failure(FusionError(self.committed ? "发送结果未知，没有重发":"官方发送通道未就绪，请在账号页面登录验证")));return}
                    guard w.url?.host=="www."+platform+".com",w.url?.path.trimmingCharacters(in:CharacterSet(charactersIn:"/"))==room else{continue}
                    do {if let state=try await w.evaluateJavaScript("window.FusionOfficialSender?.inspect("+literal(platform)+")||{}") as? JSON{
                        if state["submitted"] as? Bool==true {self.finish(.success(["submitted":true,"receipt":state.str("receipt")]));return}
                        if !state.str("error").isEmpty{self.finish(.failure(FusionError(state.str("error"))));return}
                        if !self.committed,state["ready"] as? Bool==true {self.committed=true;self.lastAttempt=Date();commitTime=Date();_ = try await w.evaluateJavaScript("window.FusionOfficialSender.commit("+literal(platform)+","+literal(text)+")")}
                    }}catch{self.finish(.failure(FusionError(self.committed ? "发送结果未知，没有重发":"官方发送页面不可用")));return}
                }
            }
        }
    }
    func cancel(){finish(.failure(FusionError(committed ? "已关闭发送通道，结果未知，没有重发":"已取消发送")))}
    private func finish(_ result:Result<JSON,Error>){let c=continuation;continuation=nil;task?.cancel();web?.stopLoading();web?.removeFromSuperview();web=nil;c?.resume(with:result)}
}

