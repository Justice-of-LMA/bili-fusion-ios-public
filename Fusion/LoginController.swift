import UIKit
import WebKit

/// No native bridge is installed on official Bili pages. Password fields are never inspected.
@MainActor final class LoginController: UIViewController, WKNavigationDelegate {
    private let web = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
    private let room: Int64
    var done: (([JSON]) -> Void)?
    init(room: Int64 = 0) { self.room = room; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    static func browserUserAgent(version: OperatingSystemVersion, tablet: Bool) -> String {
        let safariVersion = "\(version.majorVersion).\(version.minorVersion)"
        let device = tablet ? "Macintosh; Intel Mac OS X 10_15_7" : "iPhone; CPU iPhone OS \(version.majorVersion)_\(version.minorVersion) like Mac OS X"
        return "Mozilla/5.0 (\(device)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVersion) \(tablet ? "" : "Mobile/15E148 ")Safari/605.1.15"
    }
    private func loadEntry() {
        let url = URL(string: room > 0 ? "https://live.bilibili.com/\(room)" : "https://passport.bilibili.com/login")!
        web.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData))
    }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        title = room > 0 ? "B站官方房间验证" : "登录 B站"
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "完成", style: .done, target: self, action: #selector(finish))
        navigationItem.rightBarButtonItems = [UIBarButtonItem(title: "刷新", style: .plain, target: self, action: #selector(refresh)), UIBarButtonItem(title: "退出登录", style: .plain, target: self, action: #selector(logout))]
        // Include a Safari version before the first request so the site can identify WKWebView.
        web.customUserAgent = Self.browserUserAgent(version: ProcessInfo.processInfo.operatingSystemVersion,
                                                   tablet: UIDevice.current.userInterfaceIdiom == .pad)
        web.navigationDelegate = self; web.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(web)
        NSLayoutConstraint.activate([web.leadingAnchor.constraint(equalTo: view.leadingAnchor),web.trailingAnchor.constraint(equalTo: view.trailingAnchor),web.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),web.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        loadEntry()
    }
    @objc private func refresh() { loadEntry() }
    @objc private func logout() {
        let alert = UIAlertController(title: "清除本 App 内的 B站登录会话？", message: "不会退出官方客户端。", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "清除", style: .destructive) { [weak self] _ in
            let store = WKWebsiteDataStore.default()
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                let selected = records.filter { $0.displayName.lowercased().contains("bilibili") }
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: selected) {
                    self?.web.load(URLRequest(url: URL(string: "https://passport.bilibili.com/login")!))
                }
            }
        }); present(alert, animated: true)
    }
    @objc private func finish() {
        guard room > 0, web.url?.host == "live.bilibili.com" else { close([]); return }
        let script = "Array.from(document.querySelectorAll('.chat-item img,.danmaku-item img,img.emoticon,img.emoji')).slice(-200).map(x=>({url:x.currentSrc||x.src,alt:x.getAttribute('data-text')||x.alt||x.title||'',aliases:[x.alt,x.title,x.getAttribute('data-text')].filter(Boolean)}))"
        web.evaluateJavaScript(script) { [weak self] result, _ in
            let safe = (result as? [JSON] ?? []).filter { $0.str("alt").count <= 100 && URL(string: $0.str("url")).map(Safety.media) == true }
            self?.close(safe)
        }
    }
    private func close(_ emotes: [JSON]) { web.stopLoading(); dismiss(animated: true) { [weak self] in self?.done?(emotes) } }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url, url.scheme == "https", let host = url.host, Safety.inDomain(host, "bilibili.com") else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame == nil { web.load(navigationAction.request); decisionHandler(.cancel) } else { decisionHandler(.allow) }
    }
}

