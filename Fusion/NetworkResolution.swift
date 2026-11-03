import Foundation
import Network

/// A user-selected, app-scoped system resolver policy. It never retries a request,
/// changes a CDN URL, substitutes a media IP, or weakens TLS certificate checks.
@MainActor final class NetworkResolution {
    enum Mode: String, CaseIterable {
        case system, compatible, tencent, google
        var label:String {
            switch self {case .system:return "系统默认";case .compatible:return "阿里 DNS";case .tencent:return "腾讯 DNS";case .google:return "Google DNS"}
        }
    }
    struct Resolver { let url:URL;let addresses:[String] }
    static func resolver(for mode:Mode)->Resolver? {
        switch mode {
        case .system:return nil
        case .compatible:return Resolver(url:resolverURL,addresses:resolverAddresses)
        // DNSPod publishes domain-only DoH access. Its ordinary port-53 addresses
        // are deliberately not used as HTTPS bootstrap servers.
        case .tencent:return Resolver(url:URL(string:"https://doh.pub/dns-query")!,addresses:[])
        case .google:return Resolver(url:URL(string:"https://dns.google/dns-query")!,addresses:["8.8.8.8","8.8.4.4","2001:4860:4860::8888","2001:4860:4860::8844"])
        }
    }
    static let shared = NetworkResolution()
    static let key = "fusion.network-resolution.v1"
    static let resolverURL = URL(string:"https://dns.alidns.com/dns-query")!
    // Published resolver bootstrap addresses, not addresses of any video CDN.
    static let resolverAddresses = ["223.5.5.5", "223.6.6.6", "2400:3200::1", "2400:3200:baba::1"]
    private let defaults: UserDefaults
    private let applyPolicy: (Mode) -> Void
    private(set) var mode: Mode
    init(defaults: UserDefaults = .standard, apply: ((Mode) -> Void)? = nil) {
        self.defaults=defaults; self.applyPolicy=apply ?? Self.applySystemPolicy
        mode=Mode(rawValue:defaults.string(forKey:Self.key) ?? "") ?? .system
    }
    func applySaved() { applyPolicy(mode) }
    func select(_ raw: String) throws -> JSON {
        guard let selected=Mode(rawValue:raw) else { throw FusionError("网络解析选项无效") }
        applyPolicy(selected); mode=selected; defaults.set(selected.rawValue,forKey:Self.key)
        return state
    }
    var state: JSON { ["mode":mode.rawValue,"provider":mode.label] }
    private static func applySystemPolicy(_ mode: Mode) {
        let context=NWParameters.PrivacyContext.default
        if let resolver=resolver(for:mode) {
            let addresses=resolver.addresses.map { NWEndpoint.hostPort(host:NWEndpoint.Host($0),port:443) }
            context.requireEncryptedNameResolution(true,fallbackResolver:.https(resolver.url,serverAddresses:addresses))
        } else {
            context.requireEncryptedNameResolution(false,fallbackResolver:nil)
        }
    }
}
