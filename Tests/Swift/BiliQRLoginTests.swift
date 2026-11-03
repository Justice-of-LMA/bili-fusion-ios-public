import XCTest
import WebKit
@testable import Fusion

/// All challenges and login cookies below are local fixtures. No account is contacted.
final class BiliQRLoginTests: XCTestCase {
    private static let key = "fixture-qr-key-123456"
    private static let url = "https://passport.bilibili.com/h5-app/passport/login/scan?fixture=1"
    @MainActor private func settle(_ session: BiliQRLoginSession, at phase: BiliQRLoginSession.Phase) async throws {
        for _ in 0..<200 {
            if session.phase == phase { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(session.phase, phase)
    }
    private func response(_ request: URLRequest, data: JSON, cookie: String? = nil) throws -> (Data, HTTPURLResponse) {
        (try JSONSerialization.data(withJSONObject: ["code": 0, "data": data]),
         HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                         headerFields: cookie.map { ["Set-Cookie": $0] })!)
    }
    @MainActor func testChallengeValidationAndNativeQRCode() throws {
        let (url, key) = try BiliQRLoginSession.challenge(["qrcode_key": Self.key, "url": Self.url])
        XCTAssertEqual(key, Self.key); XCTAssertNotNil(BiliQRLoginController.qrImage(url))
        for invalid in ["http://passport.bilibili.com/scan", "https://passport.bilibili.com.evil.test/scan",
                        "https://user@passport.bilibili.com/scan", "https://passport.bilibili.com:444/scan"] {
            XCTAssertThrowsError(try BiliQRLoginSession.challenge(["qrcode_key": Self.key, "url": invalid]))
        }
        XCTAssertThrowsError(try BiliQRLoginSession.challenge(["qrcode_key": "short", "url": Self.url]))
    }
    @MainActor func testSuccessfulScanImportsCookiesAndKeepsExistingDeviceIdentity() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        defer { withExtendedLifetime(dataStore) {} }
        let store = dataStore.httpCookieStore
        let identity = try XCTUnwrap(HTTPCookie(properties: [.name: "buvid3", .value: "fixture-identity", .domain: ".bilibili.com", .path: "/", .secure: "TRUE"]))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in store.setCookie(identity) { c.resume() } }
        var requests = [URLRequest](), phases = [BiliQRLoginSession.Phase](), polls = 0
        let session = BiliQRLoginSession(store: store, pollNanoseconds: 1_000_000) { request in
            requests.append(request)
            if request.url?.path.hasSuffix("/generate") == true {
                return try self.response(request, data: ["url": Self.url, "qrcode_key": Self.key])
            }
            XCTAssertEqual(request.url?.path, "/x/passport-login/web/qrcode/poll")
            polls += 1
            let code = [86101, 86090, 0][min(polls - 1, 2)]
            let cookies = code == 0 ? "SESSDATA=fixture-session; Domain=.bilibili.com; Path=/; Secure; HttpOnly, bili_jct=fixture-csrf; Domain=.bilibili.com; Path=/; Secure" : nil
            return try self.response(request, data: ["code": code], cookie: cookies)
        }
        session.changed = { phases.append(session.phase) }; defer { session.cancel() }
        XCTAssertEqual(requests.count, 0); XCTAssertEqual(session.phase, .idle)
        session.start(); try await settle(session, at: .complete)
        XCTAssertEqual(polls, 3); XCTAssertTrue(phases.contains(.waiting)); XCTAssertTrue(phases.contains(.scanned))
        XCTAssertNil(session.challengeURL)
        let cookies = await withCheckedContinuation { (c: CheckedContinuation<[HTTPCookie], Never>) in store.getAllCookies { c.resume(returning: $0) } }
        XCTAssertEqual(cookies.first { $0.name == "SESSDATA" }?.value, "fixture-session")
        XCTAssertEqual(cookies.first { $0.name == "bili_jct" }?.value, "fixture-csrf")
        XCTAssertEqual(cookies.first { $0.name == "buvid3" }?.value, "fixture-identity")
        XCTAssertTrue(cookies.allSatisfy { $0.isSecure })
        for request in requests {
            XCTAssertEqual(request.url?.host, "passport.bilibili.com")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        }
        let api = BiliAPI(cookieStore: store) { request in
            let header = request.value(forHTTPHeaderField: "Cookie") ?? ""
            XCTAssertTrue(header.contains("SESSDATA=fixture-session")); XCTAssertTrue(header.contains("bili_jct=fixture-csrf"))
            return try self.response(request, data: ["isLogin": true, "uname": "fixture", "mid": 1])
        }
        let status = try await api.status(); XCTAssertEqual(status["loggedIn"] as? Bool, true)
    }
    @MainActor func testExpiryRequiresManualRefreshAndNeverStartsAnotherChallenge() async throws {
        var requests = 0
        let dataStore = WKWebsiteDataStore.nonPersistent()
        defer { withExtendedLifetime(dataStore) {} }
        let session = BiliQRLoginSession(store: dataStore.httpCookieStore, pollNanoseconds: 1_000_000) { request in
            requests += 1
            return try self.response(request, data: request.url?.path.hasSuffix("/generate") == true
                ? ["url": Self.url, "qrcode_key": Self.key] : ["code": 86038])
        }
        defer { session.cancel() }; session.start(); try await settle(session, at: .expired)
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(requests, 2); XCTAssertNil(session.challengeURL)
        session.start(); try await settle(session, at: .expired); XCTAssertEqual(requests, 4)
    }
    @MainActor func testCloseDiscardsAnInFlightSuccessfulResponse() async throws {
        let dataStore = WKWebsiteDataStore.nonPersistent()
        defer { withExtendedLifetime(dataStore) {} }
        let store = dataStore.httpCookieStore
        var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var pollRequest: URLRequest?
        let session = BiliQRLoginSession(store: store, pollNanoseconds: 1_000_000) { request in
            if request.url?.path.hasSuffix("/generate") == true {
                return try self.response(request, data: ["url": Self.url, "qrcode_key": Self.key])
            }
            pollRequest = request
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        session.start()
        for _ in 0..<100 { if pending != nil { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        session.cancel()
        let request = try XCTUnwrap(pollRequest), completion = try XCTUnwrap(pending)
        completion.resume(returning: try response(request, data: ["code": 0], cookie:
            "SESSDATA=fixture-late; Domain=.bilibili.com; Path=/; Secure, bili_jct=fixture-late; Domain=.bilibili.com; Path=/; Secure"))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(session.phase, .idle); XCTAssertNil(session.challengeURL)
        let cookies = await withCheckedContinuation { (c: CheckedContinuation<[HTTPCookie], Never>) in store.getAllCookies { c.resume(returning: $0) } }
        XCTAssertFalse(cookies.contains { $0.name == "SESSDATA" })
    }
    @MainActor func testAuthCookiesAreScopedToSuccessfulOfficialHTTPSResponse() throws {
        func response(_ value: String, url: String = "https://passport.bilibili.com/x/passport-login/web/qrcode/poll") -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: url)!, statusCode: 200, httpVersion: nil, headerFields: ["Set-Cookie": value])!
        }
        let valid = "SESSDATA=fixture; Domain=.bilibili.com; Path=/; HttpOnly"
        XCTAssertTrue(BiliQRLoginSession.acceptedCookies(response(valid), code: 86101).isEmpty)
        let accepted = try XCTUnwrap(BiliQRLoginSession.acceptedCookies(response(valid), code: 0).first)
        XCTAssertTrue(accepted.isSecure)
        for value in ["SESSDATA=fixture; Domain=.evil.test; Path=/; Secure",
                      "SESSDATA=fixture; Domain=.bilibili.com; Path=/other; Secure",
                      "SESSDATA=fixture; Domain=.bilibili.com; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT; Secure",
                      "unrelated=fixture; Domain=.bilibili.com; Path=/; Secure"] {
            XCTAssertTrue(BiliQRLoginSession.acceptedCookies(response(value), code: 0).isEmpty)
        }
        for url in ["http://passport.bilibili.com/poll", "https://passport.bilibili.com.evil.test/poll"] {
            XCTAssertTrue(BiliQRLoginSession.acceptedCookies(response(valid, url: url), code: 0).isEmpty)
        }
    }
}
