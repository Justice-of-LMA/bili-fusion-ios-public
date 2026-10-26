import UIKit
import WebKit
import CoreImage.CIFilterBuiltins
@testable import Fusion

/// Test-only, explicitly opted-in login on the temporary iOS runner, never in a release app.
/// Only the QR image leaves the simulator. Keys, response bodies and cookies never enter reports.
@MainActor enum LiveTestLogin {
    static let origin=URL(string:"https://passport.bilibili.com")!
    static func challengeURL(_ data:JSON)throws->URL{
        guard data.str("qrcode_key").matches("^[A-Za-z0-9_-]{16,128}$"),let url=URL(string:data.str("url")),url.scheme=="https",["passport.bilibili.com","account.bilibili.com"].contains(url.host ?? ""),url.user==nil,url.password==nil,url.port==nil || url.port==443 else{throw FusionError("Official login challenge was not valid")}
        return url
    }
    static func acceptedCookies(_ response:HTTPURLResponse,code:Int)->[HTTPCookie]{
        guard code==0,response.url?.host=="passport.bilibili.com" else{return []}
        let headers=response.allHeaderFields.reduce(into:[String:String]()){if let k=$1.key as? String,let v=$1.value as? String{$0[k]=v}}
        return HTTPCookie.cookies(withResponseHeaderFields:headers,for:origin).filter{c in
            let domain=c.domain.trimmingCharacters(in:CharacterSet(charactersIn:"."))
            return domain=="bilibili.com" && c.isSecure && c.path=="/" && (c.expiresDate==nil || c.expiresDate!>Date())
        }
    }
    static func request(_ path:String)async throws->(JSON,HTTPURLResponse){
        var r=URLRequest(url:URL(string:path,relativeTo:origin)!.absoluteURL)
        r.setValue(Safety.ua,forHTTPHeaderField:"User-Agent");r.setValue("https://www.bilibili.com/",forHTTPHeaderField:"Referer")
        do{
            let (bytes,response)=try await HTTP.shared.fetch(r,limit:65536)
            guard response.statusCode==200,let body=try JSONSerialization.jsonObject(with:bytes) as? JSON,body.int("code")==0 else{throw FusionError("Login service did not confirm the request")}
            return(body.obj("data"),response)
        }catch{throw FusionError("Official QR login service unavailable; no credentials were logged")}
    }
    static func authenticate(folder:URL)async throws{
        // The user scans before compilation. The host injects only this run's temporary
        // session into the simulator sandbox; no account data is a build input or artifact.
        let file=folder.appendingPathComponent("session.json")
        let deadline=Date().addingTimeInterval(60)
        while !FileManager.default.fileExists(atPath:file.path),Date()<deadline{try await Task.sleep(nanoseconds:250_000_000)}
        defer{try? FileManager.default.removeItem(at:file)}
        guard let bytes=try? Data(contentsOf:file),bytes.count<65536,let rows=try? JSONSerialization.jsonObject(with:bytes) as? [JSON] else{throw FusionError("User-authorized temporary login was not delivered; no live stream was started")}
        let store=WKWebsiteDataStore.default().httpCookieStore
        var cookies=[HTTPCookie]()
        for row in rows{
            let domain=row.str("domain"),name=row.str("name"),path=row.str("path")
            guard domain.trimmingCharacters(in:CharacterSet(charactersIn:"."))=="bilibili.com",path=="/",row["secure"] as? Bool == true,name.matches("^[A-Za-z0-9_-]{1,80}$"),row.str("value").count<8192 else{throw FusionError("Temporary session failed validation")}
            var props:[HTTPCookiePropertyKey:Any]=[.name:name,.value:row.str("value"),.domain:domain,.path:path,.secure:"TRUE"]
            if let expires=row["expires"] as? Double{guard expires>Date().timeIntervalSince1970 else{throw FusionError("Temporary session expired")};props[.expires]=Date(timeIntervalSince1970:expires)}
            guard let cookie=HTTPCookie(properties:props) else{throw FusionError("Temporary session format invalid")};cookies.append(cookie)
        }
        guard cookies.contains(where:{$0.name=="SESSDATA"}) else{throw FusionError("Temporary session was not authenticated")}
        for cookie in cookies{await withCheckedContinuation{(c:CheckedContinuation<Void,Never>) in store.setCookie(cookie){c.resume()}}}
        guard try await BiliAPI().status()["loggedIn"] as? Bool == true else{throw FusionError("Login status did not verify on iOS; no live stream was started")}
        print("IOS_BILI_LOGIN_VERIFIED: authenticated session on this iOS simulator")
    }
    static func clear()async{
        let store=WKWebsiteDataStore.default().httpCookieStore
        let all=await withCheckedContinuation{(c:CheckedContinuation<[HTTPCookie],Never>) in store.getAllCookies{c.resume(returning:$0)}}
        for cookie in all where Safety.inDomain(cookie.domain.trimmingCharacters(in:CharacterSet(charactersIn:".")),"bilibili.com"){
            await withCheckedContinuation{(c:CheckedContinuation<Void,Never>) in store.delete(cookie){c.resume()}}
        }
    }
}
