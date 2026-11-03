import UIKit
import WebKit
import CoreImage.CIFilterBuiltins

/// A user-started official login challenge. Secrets stay in memory and never enter the Web bridge.
@MainActor final class BiliQRLoginSession {
    enum Phase: Equatable { case idle, loading, waiting, scanned, expired, complete, failed }
    typealias Fetch = @MainActor (URLRequest) async throws -> (Data, HTTPURLResponse)
    static let origin = URL(string: "https://passport.bilibili.com")!
    private let store: WKHTTPCookieStore
    private let fetch: Fetch
    private let pollNanoseconds: UInt64
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private(set) var phase: Phase = .idle
    private(set) var challengeURL: URL?
    var changed: (() -> Void)?

    init(store: WKHTTPCookieStore = WKWebsiteDataStore.default().httpCookieStore,
         pollNanoseconds: UInt64 = 2_000_000_000,
         fetch: @escaping Fetch = { try await HTTP.shared.fetch($0, limit: 65536) }) {
        self.store = store; self.pollNanoseconds = pollNanoseconds; self.fetch = fetch
    }
    func start() {
        cancel(); phase = .loading; changed?()
        let id = generation
        task = Task { [weak self] in guard let self else { return }; await self.run(id) }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; challengeURL = nil; phase = .idle
    }
    private func active(_ id: UUID) -> Bool { generation == id && !Task.isCancelled }
    private func update(_ value: Phase) { phase = value; changed?() }

    static func challenge(_ data: JSON) throws -> (URL, String) {
        let key = data.str("qrcode_key")
        guard key.matches("^[A-Za-z0-9_-]{16,128}$"), let url = URL(string: data.str("url")),
              url.scheme == "https", ["passport.bilibili.com", "account.bilibili.com"].contains(url.host ?? ""),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.absoluteString.count <= 4096 else { throw FusionError("B站二维码格式无效，请重新获取") }
        return (url, key)
    }
    static func acceptedCookies(_ response: HTTPURLResponse, code: Int) -> [HTTPCookie] {
        guard code == 0, response.statusCode == 200, let url = response.url,
              url.scheme == "https", url.host == "passport.bilibili.com", url.user == nil,
              url.password == nil, url.port == nil || url.port == 443 else { return [] }
        let headers = response.allHeaderFields.reduce(into: [String: String]()) {
            if let key = $1.key as? String, let value = $1.value as? String { $0[key] = value }
        }
        let names: Set<String> = ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5", "sid"]
        return HTTPCookie.cookies(withResponseHeaderFields: headers, for: origin).compactMap { cookie in
            guard names.contains(cookie.name), !cookie.value.isEmpty, cookie.value.count <= 8192,
                  cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == "bilibili.com",
                  cookie.path == "/", cookie.expiresDate == nil || cookie.expiresDate! > Date(),
                  var properties = cookie.properties else { return nil }
            // Some official auth cookies omit Secure; only their HTTPS response is accepted,
            // and the shared session is restricted to HTTPS when importing them.
            properties[.secure] = "TRUE"
            return HTTPCookie(properties: properties)
        }
    }
    private func request(_ path: String) async throws -> (JSON, HTTPURLResponse) {
        var request = URLRequest(url: URL(string: path, relativeTo: Self.origin)!.absoluteURL,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(PlatformRoom.desktopUA, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
        let (bytes, response) = try await fetch(request)
        guard bytes.count <= 65536, response.statusCode == 200,
              response.url?.scheme == "https", response.url?.host == Self.origin.host,
              let body = try JSONSerialization.jsonObject(with: bytes) as? JSON,
              body["code"] != nil, body.int("code") == 0,
              let data = body["data"] as? JSON else { throw FusionError("B站扫码登录暂不可用") }
        return (data, response)
    }
    private func run(_ id: UUID) async {
        do {
            let (data, _) = try await request("/x/passport-login/web/qrcode/generate")
            guard active(id) else { return }
            let (url, key) = try Self.challenge(data)
            challengeURL = url; update(.waiting)
            let expires = Date().addingTimeInterval(180)
            while active(id), Date() < expires {
                try await Task.sleep(nanoseconds: pollNanoseconds)
                guard active(id) else { return }
                let (result, response) = try await request("/x/passport-login/web/qrcode/poll?qrcode_key=" + Safety.encoded(key))
                guard active(id) else { return }
                guard let code = result["code"] as? NSNumber else { throw FusionError("B站扫码状态无效") }
                switch code.intValue {
                case 86101: update(.waiting)
                case 86090: update(.scanned)
                case 86038: challengeURL = nil; update(.expired); return
                case 0:
                    let cookies = Self.acceptedCookies(response, code: 0)
                    guard cookies.contains(where: { $0.name == "SESSDATA" }),
                          cookies.contains(where: { $0.name == "bili_jct" }) else { throw FusionError("B站未返回完整登录会话") }
                    for cookie in cookies {
                        guard active(id) else { return }
                        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                            store.setCookie(cookie) { c.resume() }
                        }
                    }
                    guard active(id) else { return }
                    challengeURL = nil; update(.complete); return
                default: throw FusionError("B站扫码状态未确认")
                }
            }
            if active(id) { challengeURL = nil; update(.expired) }
        } catch {
            // Do not display URLs, response bodies, keys, or cookies in an error message.
            if active(id) { challengeURL = nil; update(.failed) }
        }
    }
}

@MainActor final class BiliQRLoginController: UIViewController {
    private let session: BiliQRLoginSession
    private let imageView = UIImageView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let refreshButton = UIButton(type: .system)
    private var finished = false
    private var displayedURL: URL?
    var done: (() -> Void)?
    init(session: BiliQRLoginSession? = nil) {
        self.session = session ?? BiliQRLoginSession(); super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "B站·客户端扫码登录"; view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "关闭", style: .plain, target: self, action: #selector(finish))
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        let stack = UIStackView(); stack.axis = .vertical; stack.alignment = .center; stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        let heading = UILabel(); heading.text = "用 B站客户端扫一扫"; heading.font = .preferredFont(forTextStyle: .title2)
        heading.adjustsFontForContentSizeCategory = true; heading.numberOfLines = 0; heading.textAlignment = .center
        let hint = UILabel(); hint.text = "扫描下方官方二维码，并在 B站客户端确认登录。\n同一台手机可截图后，在 B站扫一扫中从相册选择。"
        hint.font = .preferredFont(forTextStyle: .body); hint.adjustsFontForContentSizeCategory = true
        hint.textColor = .secondaryLabel; hint.numberOfLines = 0; hint.textAlignment = .center
        let card = UIView(); card.backgroundColor = .white; card.layer.cornerRadius = 16
        imageView.contentMode = .scaleAspectFit; imageView.layer.magnificationFilter = .nearest
        imageView.accessibilityLabel = "B站官方登录二维码"; imageView.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(imageView); card.addSubview(spinner); spinner.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .preferredFont(forTextStyle: .headline); statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.numberOfLines = 0; statusLabel.textAlignment = .center
        refreshButton.configuration = .filled(); refreshButton.setTitle("重新获取二维码", for: .normal)
        refreshButton.addTarget(self, action: #selector(refresh), for: .touchUpInside)
        for child in [heading, hint, card, statusLabel, refreshButton] { stack.addArrangedSubview(child) }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 28), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -28),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48),
            card.widthAnchor.constraint(equalToConstant: 260), card.heightAnchor.constraint(equalTo: card.widthAnchor),
            imageView.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16), imageView.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            imageView.topAnchor.constraint(equalTo: card.topAnchor, constant: 16), imageView.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
            spinner.centerXAnchor.constraint(equalTo: card.centerXAnchor), spinner.centerYAnchor.constraint(equalTo: card.centerYAnchor)
        ])
        session.changed = { [weak self] in self?.render() }
        session.start()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { session.cancel() }
    }
    @objc private func refresh() { session.start() }
    @objc private func finish() {
        guard !finished else { return }; finished = true; session.cancel()
        dismiss(animated: true) { [weak self] in self?.done?() }
    }
    private func render() {
        if displayedURL != session.challengeURL {
            displayedURL = session.challengeURL
            imageView.image = session.challengeURL.flatMap(Self.qrImage)
        }
        refreshButton.isEnabled = session.phase != .loading && session.phase != .complete
        session.phase == .loading ? spinner.startAnimating() : spinner.stopAnimating()
        statusLabel.textColor = .label
        switch session.phase {
        case .idle: statusLabel.text = ""
        case .loading: statusLabel.text = "正在获取官方二维码…"
        case .waiting: statusLabel.text = "等待 B站客户端扫码"
        case .scanned: statusLabel.text = "已扫码，请在 B站客户端确认"
        case .expired: statusLabel.text = "二维码已失效，请重新获取"
        case .failed: statusLabel.text = "扫码登录暂未完成，请重新获取或使用账号密码登录"
        case .complete: statusLabel.text = "登录成功"; finish()
        }
    }
    static func qrImage(_ url: URL) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(url.absoluteString.utf8); filter.correctionLevel = "M"
        guard let raw = filter.outputImage, let image = CIContext().createCGImage(raw.transformed(by: CGAffineTransform(scaleX: 6, y: 6)), from: raw.extent.applying(CGAffineTransform(scaleX: 6, y: 6))) else { return nil }
        return UIImage(cgImage: image)
    }
}
