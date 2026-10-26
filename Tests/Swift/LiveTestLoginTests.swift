import XCTest
@testable import Fusion

final class LiveTestLoginTests:XCTestCase{
    @MainActor func testQRRejectsForeignDomainsCredentialsAndNonHTTPS(){
        let key=String(repeating:"a",count:32)
        for url in ["http://passport.bilibili.com/","https://passport.bilibili.com.attacker.test/","https://u:p@passport.bilibili.com/","https://account.bilibili.com:8443/"]{
            XCTAssertThrowsError(try LiveTestLogin.challengeURL(["qrcode_key":key,"url":url]))
        }
        XCTAssertNoThrow(try LiveTestLogin.challengeURL(["qrcode_key":key,"url":"https://account.bilibili.com/h5/account-h5/auth/scan-web?key="+key]))
    }
    @MainActor func testPendingPollOrForeignDomainCanNeverInstallSession(){
        let url=URL(string:"https://passport.bilibili.com/x/passport-login/web/qrcode/poll")!
        func response(_ cookie:String)->HTTPURLResponse{HTTPURLResponse(url:url,statusCode:200,httpVersion:"HTTP/1.1",headerFields:["Set-Cookie":cookie])!}
        let secure=response("SESSDATA=fixture; Domain=.bilibili.com; Path=/; Secure; HttpOnly")
        XCTAssertTrue(LiveTestLogin.acceptedCookies(secure,code:86101).isEmpty)
        XCTAssertEqual(LiveTestLogin.acceptedCookies(secure,code:0).map{$0.name},["SESSDATA"])
        for bad in ["SESSDATA=fixture; Domain=.attacker.test; Path=/; Secure","SESSDATA=fixture; Domain=.bilibili.com; Path=/"]{
            XCTAssertTrue(LiveTestLogin.acceptedCookies(response(bad),code:0).isEmpty)
        }
    }
}
