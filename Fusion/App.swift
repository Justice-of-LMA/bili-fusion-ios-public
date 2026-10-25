import UIKit
import AVFoundation
import WebKit

@main @MainActor final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        return true
    }
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = FusionSceneDelegate.self
        return configuration
    }
}

@MainActor final class FusionSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = FusionController()
        self.window = window
        (UIApplication.shared.delegate as? AppDelegate)?.window = window
        window.makeKeyAndVisible()
    }
    func sceneDidEnterBackground(_ scene: UIScene) { (window?.rootViewController as? FusionController)?.sceneBackground() }
    func sceneWillEnterForeground(_ scene: UIScene) { (window?.rootViewController as? FusionController)?.sceneForeground() }
    func sceneDidBecomeActive(_ scene:UIScene){(window?.rootViewController as? FusionController)?.sceneActive()}
}

@MainActor final class FusionController: UIViewController, WKScriptMessageHandler, WKNavigationDelegate {
    private var web: WKWebView!
    private let api = BiliAPI(), proxy = MediaProxy(), platforms = PlatformAPI(), platformSender = PlatformSender()
    private var pipPlatform="bilibili"
    private let messagePiP = MessagePictureInPicture()
    private let videoPiP=VideoPictureInPicture()
    private var pipRoom = "",messagePriorAudioOnly:Bool?
    private(set) var backgroundMode="audio",orientationChoice="auto"
    private var inBackground=false,accountPresented=false,lifecycleDetail=""
    private var orientationMask:UIInterfaceOrientationMask{orientationChoice=="landscape" ? .landscape:orientationChoice=="portrait" ? .portrait:UIDevice.current.userInterfaceIdiom == .pad ? .all:.allButUpsideDown}
    private let players = ["A": NativePlayer(), "B": NativePlayer()]
    private var sockets = [String: any ChatConnection](), learned = [String: [JSON]]()
    private var timer: Timer?, pending = 0, full = false, ready = false
    private var layouts = [String: CGRect](), shown = [String: Bool]()
    private let assets: WebAssets
    private let startupOverlay = StartupOverlay()
    private var startupTimeout: Task<Void, Never>?, startupGeneration = 0, contentRecoveries = 0
    private var homeNavigation: WKNavigation?
    private var webBottom: NSLayoutConstraint!
    private var webLeading:NSLayoutConstraint!,webTrailing:NSLayoutConstraint!,webTop:NSLayoutConstraint!
    private var keyboardOverlap:CGFloat=0
    var isMediaProxyRunning: Bool { proxy.isRunning }
    init(assets: WebAssets = WebAssets()) { self.assets = assets; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var prefersStatusBarHidden: Bool { full }
    override var prefersHomeIndicatorAutoHidden: Bool { full }
    override var supportedInterfaceOrientations:UIInterfaceOrientationMask{orientationMask}
    override var shouldAutorotate:Bool{true}
    @available(iOS 26.0,*) override var prefersInterfaceOrientationLocked:Bool{full && orientationChoice != "auto"}
    var presentationOrientation:String{guard web != nil else{return "portrait"};return web.bounds.width>web.bounds.height ? "landscape":"portrait"}
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = UIColor(red: 0.043, green: 0.071, blue: 0.125, alpha: 1)
        // Opening the home page must not claim audio or interrupt another app. Activate only
        // for explicit playback, PiP, or resuming an existing, non-user-paused item.
        try? AVAudioSession.sharedInstance().setCategory(.playback,mode:.moviePlayback,options:[.mixWithOthers])
        for p in players.values { view.addSubview(p.surface) }
        messagePiP.clock = { [weak self] in
            guard let state = self?.players["B"]?.snapshot() else { return (0,nil,true,false) }
            return ((state["currentTime"] as? Double) ?? 0,(state["ranges"] as? [[Double]])?.last?.last,
                    state["paused"] as? Bool ?? true,state.int("readyState") >= 3)
        }
        messagePiP.onPlaying = { [weak self] playing in
            guard let self else { return }
            if playing { do{try self.activateAudio();self.players["B"]?.play()}catch{self.lifecycleDetail=error.localizedDescription;self.notifyLifecycle()} } else { self.players["B"]?.pause() }
            self.js("window.pipPlayback?.(\(playing))")
        }
        messagePiP.onState = { [weak self] state, detail in
            guard let self else { return }
            self.js("window.pipState?.(\(self.json(state)),\(self.json(detail)))")
            if state == "active" {
                self.players["A"]?.setMessagePiPOnly(true)
            } else if state == "stopped" || state == "error" {
                self.players["A"]?.setMessagePiPOnly(false)
                if let previous=self.messagePriorAudioOnly{self.players["B"]?.setAudioOnly(previous);self.messagePriorAudioOnly=nil}
                self.applyBackgroundPolicy()
            }
            self.notifyLifecycle()
        }
        messagePiP.onRestore = { [weak self] in self?.js("window.pipRestored?.()") }
        videoPiP.onState={ [weak self] state,detail in guard let self else{return};self.lifecycleDetail=detail;if state=="stopped"||state=="error"{self.applyBackgroundPolicy()};self.notifyLifecycle();self.js("window.videoPiPState?.(\(self.json(state)),\(self.json(detail)))") }
        videoPiP.onRestore={ [weak self] in self?.sceneForeground();self?.js("window.videoPiPRestored?.()") }
        let configuration = WKWebViewConfiguration(); configuration.setURLSchemeHandler(assets, forURLScheme: "fusion")
        configuration.allowsInlineMediaPlayback = true; configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "fusion")
        let bridge = "if(location.protocol==='fusion:'&&location.host==='app'){window.Native={call:(id,op,payload)=>window.webkit.messageHandlers.fusion.postMessage({id,op,payload})};}"
        configuration.userContentController.addUserScript(WKUserScript(source: bridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: .zero, configuration: configuration); web.navigationDelegate = self
        web.isOpaque = false; web.backgroundColor = .clear; web.scrollView.backgroundColor = .clear; web.translatesAutoresizingMaskIntoConstraints = false
        web.scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(web)
        // The initial page must have a real height even before iPad keyboard geometry is available.
        // Size/centre constraints permit an app-local rotation when a resizable iPad scene declines an orientation request.
        webLeading=web.widthAnchor.constraint(equalToConstant:1);webTrailing=web.heightAnchor.constraint(equalToConstant:1);webTop=web.centerXAnchor.constraint(equalTo:view.centerXAnchor);webBottom=web.centerYAnchor.constraint(equalTo:view.centerYAnchor)
        NSLayoutConstraint.activate([webLeading,webTrailing,webTop,webBottom])
        startupOverlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(startupOverlay)
        NSLayoutConstraint.activate([startupOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor), startupOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor), startupOverlay.topAnchor.constraint(equalTo: view.topAnchor), startupOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        startupOverlay.onRetry = { [weak self] in self?.reloadHome() }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(interruption(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self,selector:#selector(routeChanged(_:)),name:AVAudioSession.routeChangeNotification,object:nil)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        // Local HTML is independent of AVPlayer, loopback networking, Bili login and connectivity.
        reloadHome()
    }
    private func reloadHome() {
        videoPiP.stop()
        messagePiP.stop()
        startupGeneration += 1; let generation = startupGeneration
        startupTimeout?.cancel(); web.stopLoading()
        for p in players.values { p.close() }; stopSockets(); proxy.stop()
        UIApplication.shared.isIdleTimerDisabled = false
        startupOverlay.show("正在打开首页…", canRetry: false)
        ready = true
        homeNavigation = web.load(URLRequest(url: URL(string: "fusion://app/index.html")!))
        startupTimeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
            guard let self, self.startupGeneration == generation else { return }
            self.startupOverlay.show("首页加载超时（BOOT-TIMEOUT）。\n请点重新加载；若仍失败，请将此页面截图反馈。", canRetry: true)
        }
    }
    private func pageFailed(_ error: Error) {
        startupTimeout?.cancel()
        let error = error as NSError
        let detail = WebAssetError.diagnostic(error).map { "\n\($0)。" } ?? ""
        startupOverlay.show("首页未能加载（\(error.domain) / \(error.code)）。\(detail)\n请点重新加载，或将此页面截图反馈。", canRetry: true)
    }
    @objc private func keyboardChanged(_ notification: Notification) {
        guard web != nil, let window = view.window else { return }
        var overlap: CGFloat = 0
        if notification.name != UIResponder.keyboardWillHideNotification,
           let screenRect = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
            let rect = view.convert(window.convert(screenRect, from: nil), from: window)
            let safe = view.safeAreaLayoutGuide.layoutFrame
            if rect.width >= safe.width * 0.8 && rect.maxY >= safe.maxY - 2 { overlap = max(0, safe.maxY - rect.minY) }
        }
        keyboardOverlap=min(overlap,max(0,view.bounds.height-160));updateWebInsets()
        view.layoutIfNeeded()
    }
    private func updateWebInsets(){
        guard webLeading != nil else{return}
        var area=full ? view.bounds:view.safeAreaLayoutGuide.layoutFrame
        area.size.height=max(1,area.height-keyboardOverlap)
        let landscape=orientationChoice=="landscape",portrait=orientationChoice=="portrait"
        let rotate=(landscape && area.width<area.height)||(portrait && area.width>area.height)
        webLeading.constant=max(1,rotate ? area.height:area.width);webTrailing.constant=max(1,rotate ? area.width:area.height)
        webTop.constant=area.midX-view.bounds.midX;webBottom.constant=area.midY-view.bounds.midY
        web.transform=rotate ? CGAffineTransform(rotationAngle:landscape ? .pi/2:-.pi/2):.identity
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews();updateWebInsets(); applyLayout(); if messagePiP.enabled { messagePiP.layout(in:view) }; js("window.iosLayout?.()") }
    override func viewWillTransition(to size:CGSize,with coordinator:UIViewControllerTransitionCoordinator){super.viewWillTransition(to:size,with:coordinator);coordinator.animate(alongsideTransition:nil){[weak self] _ in guard let self else{return};self.updateWebInsets();self.view.layoutIfNeeded();self.applyLayout();self.js("window.orientationState?.(\(self.json(["requested":self.orientationChoice,"actual":self.presentationOrientation])))")}}
    private func json(_ value: Any) -> String { String(data: (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data("null".utf8), encoding: .utf8) ?? "null" }
    private func js(_ script: String) { guard ready, web?.url?.scheme == "fusion", web?.url?.host == "app" else { return }; web.evaluateJavaScript(script, completionHandler: nil) }
    private func reply(_ id: String, _ result: Any?, _ error: String? = nil) {
        guard web?.url?.scheme == "fusion", web?.url?.host == "app" else { return }
        // A local preference read can finish before didFinish marks the whole page ready.
        web.evaluateJavaScript("window.receiveNative?.(\(json(id)),\(json(result ?? NSNull())),\(json(error as Any? ?? NSNull())))",completionHandler:nil)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "fusion", message.frameInfo.securityOrigin.host == "app", web.url?.scheme == "fusion", let envelope = message.body as? JSON,
              let id = envelope["id"] as? String, id.matches("^[0-9]{1,12}$"), let op = envelope["op"] as? String,
              let payload = envelope["payload"] as? String, payload.utf8.count <= (op == "blockingSet" ? 524288 : 8192), let data = payload.data(using: .utf8), let args = try? JSONSerialization.jsonObject(with: data) as? JSON else { return }
        if op == "layout" { layout(args); return }
        if op == "videoZoom" { let source=args.str("source");if let p=players[source],p.token==args.str("token"){p.surface.zoom(scale:CGFloat((args["scale"] as? NSNumber)?.doubleValue ?? 1),x:CGFloat((args["x"] as? NSNumber)?.doubleValue ?? 0),y:CGFloat((args["y"] as? NSNumber)?.doubleValue ?? 0))};return }
        guard pending < 16 else { reply(id, nil, "操作过于频繁"); return }
        pending += 1
        Task {
            defer { pending -= 1 }
            do { reply(id, try await operation(op, args)) }
            catch { reply(id, nil, error.localizedDescription) }
        }
    }
    private func operation(_ op: String, _ a: JSON) async throws -> Any {
        let platform=a.str("platform").isEmpty ? "bilibili":a.str("platform")
        guard ["bilibili","huya","douyu"].contains(platform) else { throw FusionError("不支持的平台") }
        switch op {
        case "blockingGet": return BlockRules.load()
        case "blockingSet":
            let rules = BlockRules.save(a.obj("rules")); messagePiP.setBlocking(rules); return rules
        case "status": return try await api.status()
        case "preview": if platform=="bilibili" {return try await api.preview(a.str("room"))};return try await platforms.preview(platform,a.str("room"))
        case "following": return try await api.following(a.int("page"))
        case "resolve": if platform=="bilibili" {return try await api.resolve(a.str("room"),quality:a.int("quality"),preferTS:a["voice"] as? Bool ?? false)};return try await platforms.resolve(platform,a.str("room"),quality:a.int("quality"))
        case "emojis":
            let room = String(try Safety.room(a.str("room")))
            let data = try await api.data("/xlive/web-ucenter/v2/emoticon/GetEmoticons?platform=pc&room_id=\(room)")
            if room == pipRoom { messagePiP.learn(data) }; return data
        case "snapshot":
            let room = String(try Safety.room(a.str("room")))
            let data = try await api.data("/xlive/web-room/v1/index/getInfoByRoom?room_id=\(room)")
            if room == pipRoom { for card in data.obj("super_chat_info").arr("message_list") { messagePiP.receive(["packet":["cmd":"SUPER_CHAT_MESSAGE","data":card]]) } }
            return data
        case "learned": return learned[String(try Safety.room(a.str("room")))] ?? []
        case "send":
            if platform=="bilibili" { return try await api.send(room:Safety.room(a.str("room")),text:a.str("text"),uid:a.int64("uid")) }
            return try await platformSender.send(platform:platform,room:a.str("room"),text:a.str("text"),host:view)
        case "platformFollowing": showPlatform(platform:platform,source:a.str("source"),picking:true)
        case "stopChat": stopSockets()
        case "startChat":
            let source=a.str("source"),epoch=a.str("epoch"),room=try PlatformRoom.id(platform,a.str("room"))
            guard ["A","B"].contains(source), epoch.matches("^[A-Za-z0-9-]{1,80}$") else { throw FusionError("连接参数无效") }
            sockets[source]?.close()
            if source == "B" {
                pipPlatform=platform;pipRoom = room; messagePiP.selectRoom(pipRoom,title:a.str("title").isEmpty ? "二路消息 · \(room)" : a.str("title"),platform:platform)
                if let cached = learned[pipRoom] { messagePiP.learn(cached) }
            }
            let receive: (JSON)->Void = { [weak self] event in
                guard let self else { return }
                if source == "B" { self.messagePiP.receive(event) }
                // Native list rendering keeps working without background JavaScript evaluation.
                if UIApplication.shared.applicationState == .active { self.js("window.liveEvent?.(\(self.json(source)),\(self.json(epoch)),\(self.json(event)))") }
            }
            let socket:any ChatConnection
            if platform=="bilibili" {socket=LiveSocket(api:api,room:try Safety.room(room),sink:receive)} else if platform=="douyu" {socket=DouyuChat(room:room,sink:receive)} else {socket=HuyaPageChat(room:room,host:view,sink:receive)}
            sockets[source] = socket; socket.start()
        case "pipStart":
            guard !videoPiP.enabled else{throw FusionError("请先关闭视频小窗，再开启二路消息画中画")};videoPiP.disarmAutomatic()
            guard sockets["B"] != nil, let b = players["B"], !b.token.isEmpty else { throw FusionError("请先连接二路直播间") }
            guard pipPlatform != "huya" else{throw FusionError("虎牙当前使用官方页面消息列表，切到后台可能停止更新；消息画中画请先选 B站或斗鱼 HLS 房间")}
            try AVAudioSession.sharedInstance().setCategory(.playback,mode:.default,options:[.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            messagePiP.configure(a);messagePriorAudioOnly=b.isAudioOnly;b.setAudioOnly(true)
            do { try messagePiP.start(in:view) }
            catch {if let previous=messagePriorAudioOnly{b.setAudioOnly(previous);messagePriorAudioOnly=nil};throw error }
        case "pipStop": messagePiP.stop()
        case "pipSettings": messagePiP.configure(a)
        case "pipPause": messagePiP.setPaused(a["value"] as? Bool ?? false)
        case "login":
            if platform=="bilibili" {showLogin(room:0)} else {showPlatform(platform:platform,source:"B",picking:false)}
        case "verify":
            if platform=="bilibili" {showLogin(room:try Safety.room(a.str("room")))} else {showPlatform(platform:platform,source:a.str("source"),picking:true)}
        case "fullscreen":
            setNativeFullscreen(a["value"] as? Bool ?? false)
        case "orientation": return try requestOrientation(a.str("value"))
        case "backgroundMode": return try setBackgroundMode(a.str("value"))
        case "playbackState": return lifecycleState()
        case "videoPiPStart","videoPiP":
            if a["value"] as? Bool == false{videoPiP.stop();return lifecycleState()}
            let source=a.str("source").isEmpty ? "A":a.str("source")
            guard let p=players[source],!messagePiP.enabled else{throw FusionError("请先关闭消息画中画，并选择 A / B 原生视频")}
            try activateAudio();try videoPiP.start(p,source:source);return lifecycleState()
        case "videoPiPStop":videoPiP.stop();return lifecycleState()
        case "donate":
            let receipt = "https://qr.alipay.com/fkx147310zewbxibkimao8c?t=1787991881397"
            let scheme = URL(string: "alipays://platformapi/startapp?saId=10000007&qrcode=" + Safety.encoded(receipt))!
            let opened = await UIApplication.shared.open(scheme)
            if !opened { let fallback = await UIApplication.shared.open(URL(string: receipt)!); if !fallback { throw FusionError("无法打开支付宝，请使用收款码") } }
        case "mediaWebURL":
            let source=a.str("source");guard ["A","B"].contains(source),a.str("token").matches("^[A-Za-z0-9-]{1,100}$"),let url=URL(string:a.str("url")),Safety.media(url) else{throw FusionError("媒体地址无效")};if videoPiP.source==source{videoPiP.stop()};players[source]?.close();try await proxy.start();return ["url":try proxy.register(url,owner:proxy.begin(source,token:a.str("token"))).absoluteString]
        case "voiceMode": return ["ai":VoiceSegment.aiEnabled]
        case "mediaVoice":
            let strength=(a["strength"] as? NSNumber)?.floatValue ?? 0
            if VoiceSegment.aiEnabled && strength > 0 {
                let available=await Task.detached(priority:.userInitiated) { VoiceSegment.initializeAI() }.value
                guard available else { throw FusionError("AI 模型加载失败，保留原声音："+VoiceSegment.aiDetail) }
            }
            proxy.setVoice("A",strength:strength)
        case "mediaOpen", "mediaPlay", "mediaPause", "mediaSeek", "mediaVolume", "mediaAudioOnly", "mediaClose":
            let source = a.str("source"), token = a.str("token")
            guard let p = players[source], token.matches("^[A-Za-z0-9-]{1,100}$") else { throw FusionError("播放器参数无效") }
            if op == "mediaOpen" {
                if videoPiP.source==source{videoPiP.stop()}
                if source == "B" { messagePiP.stop() }
                guard let url = URL(string: a.str("url")), Safety.media(url) else { throw FusionError("直播线路无效") }
                try await proxy.start()
                p.open(url: try proxy.register(url,owner:proxy.begin(source,token:token)), token: token, volume: (a["volume"] as? NSNumber)?.floatValue ?? 1, audioOnly: source == "B" && a["audioOnly"] as? Bool == true); applyLayout()
                if source=="A",backgroundMode=="video-pip",!messagePiP.enabled{try? videoPiP.prepareAutomatic(p,source:source)}
                UIApplication.shared.isIdleTimerDisabled = true
            } else if token == p.token {
                switch op {
                case "mediaPlay":try activateAudio();p.play()
                case "mediaPause": p.pause()
                case "mediaSeek": try await p.seek((a["time"] as? NSNumber)?.doubleValue ?? .nan); return ["ok":true,"state":p.snapshot()]
                case "mediaVolume": p.player.volume = max(0, min(1, (a["volume"] as? NSNumber)?.floatValue ?? 1))
                case "mediaAudioOnly": p.setAudioOnly(source == "B" && a["value"] as? Bool == true)
                default: if source == "B" { messagePiP.stop() };if videoPiP.source==source{videoPiP.stop()};p.close(); UIApplication.shared.isIdleTimerDisabled = players.values.contains { !$0.token.isEmpty }
                }
            }
        default: throw FusionError("不支持的操作")
        }
        return ["ok": true]
    }
    private func showPlatform(platform:String,source:String,picking:Bool){
        guard ["huya","douyu"].contains(platform),presentedViewController==nil else{return};messagePiP.stop();suspend()
        let page=PlatformAccountController(platform:platform,source:source,picking:picking)
        page.selected={ [weak self] room in guard let self else{return};self.js("window.platformRoomSelected?.(\(self.json(source)),\(self.json(platform)),\(self.json(room)))") }
        page.done={ [weak self] in self?.foreground() };let nav=UINavigationController(rootViewController:page);nav.modalPresentationStyle = .fullScreen;present(nav,animated:true)
    }
    private func showLogin(room: Int64) {
        guard presentedViewController == nil else { return }
        messagePiP.stop()
        suspend()
        let login = LoginController(room: room)
        login.done = { [weak self] emotes in if room > 0 { self?.learned[String(room)] = emotes }; self?.foreground() }
        let nav = UINavigationController(rootViewController: login); nav.modalPresentationStyle = .fullScreen
        present(nav, animated: true)
    }
    private func layout(_ args: JSON) {
        for source in ["A","B"] {
            let d = args.obj(source)
            func number(_ key: String) -> CGFloat { CGFloat((d[key] as? NSNumber)?.doubleValue ?? 0) }
            let rect = CGRect(x: number("x"), y: number("y"), width: number("width"), height: number("height"))
            guard [rect.minX,rect.minY,rect.width,rect.height].allSatisfy({ $0.isFinite && abs($0) < 20000 }) else { continue }
            layouts[source] = rect; shown[source] = d["visible"] as? Bool ?? false
        }
        applyLayout()
    }
    private func applyLayout() {
        guard web != nil else { return }
        for (source, p) in players {
            let rect = layouts[source] ?? .zero
            p.surface.transform=web.transform;p.surface.bounds=CGRect(origin:.zero,size:rect.size);p.surface.center=web.convert(CGPoint(x:rect.midX,y:rect.midY),to:view)
            p.surface.isHidden = shown[source] != true || p.token.isEmpty || !p.surface.frame.intersects(web.frame)
            p.surface.layer.cornerRadius = full ? 0 : 12
        }
    }
    private func tick() { guard UIApplication.shared.applicationState == .active else { return }; js("window.__fusionVoiceStatus?.(\(json(proxy.voiceDetail("A"))))"); js("window.iosMediaState?.(\(json(players.mapValues { $0.snapshot() })))") }
    private func stopSockets() { platformSender.cancel();videoPiP.stop();messagePiP.stop(); for s in sockets.values { s.close() }; sockets.removeAll() }
    private func suspend() {accountPresented=true;platformSender.cancel();for p in players.values{p.suspendForAccount(true)};UIApplication.shared.isIdleTimerDisabled=false;notifyLifecycle()}
    func setNativeFullscreen(_ value:Bool){full=value;setNeedsStatusBarAppearanceUpdate();setNeedsUpdateOfHomeIndicatorAutoHidden();if #available(iOS 26.0,*){setNeedsUpdateOfPrefersInterfaceOrientationLocked()};updateWebInsets();view.setNeedsLayout();notifyLifecycle()}
    func requestOrientation(_ value:String)throws->JSON{
        guard ["auto","landscape","portrait"].contains(value) else{throw FusionError("屏幕方向参数无效")}
        guard let scene=view.window?.windowScene else{throw FusionError("窗口尚未就绪，请稍后再试横竖屏切换")}
        orientationChoice=value;setNeedsUpdateOfSupportedInterfaceOrientations();if #available(iOS 26.0,*){setNeedsUpdateOfPrefersInterfaceOrientationLocked()};updateWebInsets();view.layoutIfNeeded();applyLayout();js("window.iosLayout?.()")
        scene.requestGeometryUpdate(.iOS(interfaceOrientations:orientationMask)){[weak self] error in Task{@MainActor in guard let self else{return};self.updateWebInsets();self.view.layoutIfNeeded();self.applyLayout();self.lifecycleDetail="系统窗口方向受限，已在应用内切换横竖画面，未刷新直播";self.notifyLifecycle();self.js("window.orientationState?.(\(self.json(["requested":value,"actual":self.presentationOrientation,"detail":self.lifecycleDetail])))")}}
        return ["requested":value,"actual":presentationOrientation,"pending":true]
    }
    func setBackgroundMode(_ value:String)throws->JSON{
        guard ["audio","pause","video-pip"].contains(value) else{throw FusionError("后台播放设置无效")};backgroundMode=value
        if value=="video-pip",!messagePiP.enabled,let a=players["A"]{try videoPiP.prepareAutomatic(a,source:"A")}else{videoPiP.disarmAutomatic()}
        applyBackgroundPolicy();notifyLifecycle();return lifecycleState()
    }
    private func activateAudio()throws{let audio=AVAudioSession.sharedInstance();try audio.setCategory(.playback,mode:.moviePlayback,options:[.mixWithOthers]);try audio.setActive(true)}
    func lifecycleState()->JSON{["foreground":!inBackground,"backgroundMode":backgroundMode,"accountPresented":accountPresented,"videoPiP":videoPiP.enabled,"videoPiPActive":videoPiP.active,"videoPiPArmed":videoPiP.armed,"videoPiPSource":videoPiP.source,"messagePiP":messagePiP.enabled,"orientation":orientationChoice,"presentationOrientation":presentationOrientation,"full":full,"players":players.mapValues{$0.snapshot()},"detail":lifecycleDetail]}
    private func notifyLifecycle(){js("window.playbackLifecycle?.(\(json(lifecycleState())))")}
    private func applyBackgroundPolicy(){
        guard inBackground else{return}
        for(source,p)in players{
            let video=(videoPiP.enabled||videoPiP.armed)&&videoPiP.source==source
            let audio=backgroundMode != "pause" || videoPiP.enabled || (messagePiP.enabled&&source=="B")
            p.enterBackground(continueAudio:audio,keepVideoForPiP:video)
        }
    }
    func sceneBackground() {
        inBackground=true;platformSender.cancel();applyBackgroundPolicy();UIApplication.shared.isIdleTimerDisabled=false;notifyLifecycle()
    }
    func sceneForeground() { foreground() }
    func sceneActive(){foreground()}
    @objc private func foreground() {
        inBackground=false;accountPresented=presentedViewController != nil
        if !accountPresented,players.values.contains(where:{$0.wantsPlayback && $0.systemAllowsPlayback}){do{try activateAudio()}catch{for p in players.values{p.interruptionBegan()};lifecycleDetail="音频暂未恢复，请手动继续："+error.localizedDescription}}
        for p in players.values{p.suspendForAccount(accountPresented);p.enterForeground()}
        UIApplication.shared.isIdleTimerDisabled=players.values.contains{$0.wantsPlayback};applyLayout();tick();notifyLifecycle()
    }
    @objc private func interruption(_ n: Notification) {
        guard let raw=(n.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,let type=AVAudioSession.InterruptionType(rawValue:raw) else{return}
        if type == .began{for p in players.values{p.interruptionBegan()};lifecycleDetail="声音被系统或其他 App 暂时中断，未刷新直播"}
        else if type == .ended{
            let options=AVAudioSession.InterruptionOptions(rawValue:(n.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0)
            var resume=options.contains(.shouldResume)
            if resume && players.values.contains(where:{$0.wantsPlayback}){do{try activateAudio()}catch{resume=false}}
            for p in players.values{p.interruptionEnded(shouldResume:resume)}
            lifecycleDetail=resume ? "音频中断结束，按原播放 / 暂停状态恢复，未刷新直播":"音频中断结束，请手动继续；保留原直播和缓存"
        }
        notifyLifecycle()
    }
    @objc private func routeChanged(_ n:Notification){guard (n.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue==AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else{return};for p in players.values{p.routeDisconnected()};lifecycleDetail="音频设备已断开，为避免外放已暂停；请手动继续";notifyLifecycle()}
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        decisionHandler(url?.scheme == "fusion" && url?.host == "app" && url?.path == "/index.html" ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard navigation === homeNavigation else { return }
        let generation = startupGeneration
        webView.evaluateJavaScript("window.__fusionUIReady === true && document.getElementById('login').getBoundingClientRect().height > 0") { [weak self] result, error in
            guard let self, self.startupGeneration == generation else { return }
            self.startupTimeout?.cancel()
            if result as? Bool == true {
                self.startupOverlay.isHidden = true
                self.notifyLifecycle()
            } else {
                self.startupOverlay.show("首页脚本未就绪（BOOT-SCRIPT）。\n请点重新加载，或将此页面截图反馈。", canRetry: true)
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard navigation === homeNavigation, (error as NSError).code != NSURLErrorCancelled else { return }; pageFailed(error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard navigation === homeNavigation, (error as NSError).code != NSURLErrorCancelled else { return }; pageFailed(error)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // A suspended/reclaimed WK process is not a failed native stream. Keep original
        // AVPlayers/audio, proxy and existing sockets; never reload/reconnect behind the user.
        startupTimeout?.cancel();contentRecoveries += 1
        startupOverlay.show("界面进程已退出（BOOT-WEBKIT），原生播放未自动刷新。\n可先继续听声音；点重新加载会停止原播放并重开首页。",canRetry:true)
    }
    deinit { startupTimeout?.cancel(); timer?.invalidate(); NotificationCenter.default.removeObserver(self) }
}
