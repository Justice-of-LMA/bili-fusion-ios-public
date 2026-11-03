import Foundation
import Network

/// A user-selected, app-scoped system resolver policy. It never retries a request,
/// changes a CDN URL, substitutes a media IP, or weakens TLS certificate checks.
@MainActor final class NetworkResolution {
    enum Mode: String { case system, compatible }
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
    var state: JSON { ["mode":mode.rawValue,"provider":mode == .compatible ? "阿里公共 DNS":"系统默认"] }
    private static func applySystemPolicy(_ mode: Mode) {
        let context=NWParameters.PrivacyContext.default
        if mode == .compatible {
            let addresses=resolverAddresses.map { NWEndpoint.hostPort(host:NWEndpoint.Host($0),port:443) }
            context.requireEncryptedNameResolution(true,fallbackResolver:.https(resolverURL,serverAddresses:addresses))
        } else {
            context.requireEncryptedNameResolution(false,fallbackResolver:nil)
        }
    }
}
