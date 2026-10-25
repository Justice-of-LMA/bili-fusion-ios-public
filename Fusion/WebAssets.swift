import Foundation
import WebKit

/// Stable, non-sensitive diagnostics survive the NSError bridge through WebKit.
enum WebAssetError: Int, Error, LocalizedError, CustomNSError {
    case origin = 101, path = 102, root = 103, outsideRoot = 104
    case missing = 105, unreadable = 106, size = 107
    static var errorDomain: String { "Fusion.WebAssets" }
    var errorCode: Int { rawValue }
    var errorDescription: String? {
        switch self {
        case .origin: return "本地页面请求来源无效"
        case .path: return "请求的资源不在应用首页清单中"
        case .root: return "安装包内缺少 Web 首页目录"
        case .outsideRoot: return "首页资源指向了安装目录以外"
        case .missing: return "安装包内缺少请求的首页文件"
        case .unreadable: return "系统无法读取安装包内的首页文件"
        case .size: return "首页资源文件大小异常"
        }
    }
    var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? "首页资源错误"] }
    static func diagnostic(_ error: NSError) -> String? {
        if error.domain == errorDomain, let known = Self(rawValue: error.code) { return known.errorDescription }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == errorDomain {
            return Self(rawValue: underlying.code)?.errorDescription
        }
        return nil
    }
}

struct WebAssetStore {
    static let paths: Set<String> = [
        "/index.html", "/app.js", "/core.js", "/ios-media.js", "/app.css", "/ios.css", "/sc-layout.js", "/blocking.js", "/blocking-ui.js", "/danmaku-common.js", "/voice-reducer.js", "/voice-worklet.js", "/huya-chat-dom.js", "/official-chat-sender.js", "/vendor/crypto-core.js", "/vendor/crypto-md5.js", "/vendor/crypto-LICENSE.txt", "/vendor/mpegts.js", "/vendor/mpegts-LICENSE.txt",
        "/donate-alipay.jpg", "/donate-wechat.jpg", "/NOTICES.txt", "/vendor/desktop-MIT-notice.txt"
    ]
    static var bundledRoot: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true)
    }
    let root: URL?

    func load(_ url: URL, method: String = "GET") throws -> (data: Data, mime: String) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "fusion", parts.host == "app", parts.user == nil,
              parts.password == nil, parts.port == nil, method == "GET" else { throw WebAssetError.origin }
        // Fixed ASCII names need no decoding. Reject encoded separators and traversal.
        // Only these packaged assets are ever served, not arbitrary filesystem content.
        let path = parts.percentEncodedPath
        guard Self.paths.contains(path) else { throw WebAssetError.path }
        guard let root, root.isFileURL else { throw WebAssetError.root }
        // A real iPad may expose /private/var and /var aliases. Canonicalize BOTH sides,
        // then compare components, never a normalized child against a raw string prefix.
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonicalRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw WebAssetError.root }
        let file = canonicalRoot.appendingPathComponent(String(path.dropFirst()))
            .standardizedFileURL.resolvingSymlinksInPath()
        let parentComponents = canonicalRoot.pathComponents
        guard file.pathComponents.count > parentComponents.count,
              Array(file.pathComponents.prefix(parentComponents.count)) == parentComponents else { throw WebAssetError.outsideRoot }
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else { throw WebAssetError.missing }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let length = attributes[.size] as? NSNumber else { throw WebAssetError.unreadable }
        guard length.intValue > 0, length.intValue < 4 * 1024 * 1024 else { throw WebAssetError.size }
        guard let bytes = try? Data(contentsOf: file) else { throw WebAssetError.unreadable }
        guard !bytes.isEmpty, bytes.count < 4 * 1024 * 1024 else { throw WebAssetError.size }
        let mime = ["html": "text/html", "js": "application/javascript", "css": "text/css",
                    "jpg": "image/jpeg", "png": "image/png", "txt": "text/plain"][file.pathExtension] ?? "application/octet-stream"
        return (bytes, mime)
    }
}

final class WebAssets: NSObject, WKURLSchemeHandler {
    private let store: WebAssetStore
    init(root: URL? = WebAssetStore.bundledRoot) { store = WebAssetStore(root: root); super.init() }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            guard let url = urlSchemeTask.request.url else { throw WebAssetError.origin }
            let asset = try store.load(url, method: urlSchemeTask.request.httpMethod ?? "GET")
            let response = URLResponse(url: url, mimeType: asset.mime, expectedContentLength: asset.data.count,
                                       textEncodingName: asset.mime.hasPrefix("image/") ? nil : "utf-8")
            urlSchemeTask.didReceive(response); urlSchemeTask.didReceive(asset.data); urlSchemeTask.didFinish()
        } catch { urlSchemeTask.didFailWithError(error) }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}
