// Explicit user-authorized CI login. Only a QR PNG goes to the artifact service.
// The pending key and session stay in RUNNER_TEMP on this one temporary Mac.
import Foundation
import AppKit
import CoreImage.CIFilterBuiltins

struct LoginFailure:Error{let message:String}
let mode=CommandLine.arguments.dropFirst().first ?? ""
let environment=ProcessInfo.processInfo.environment
guard let temp=environment["RUNNER_TEMP"],let workspace=environment["GITHUB_WORKSPACE"] else{fatalError("CI environment required")}
let privateFolder=URL(fileURLWithPath:temp).appendingPathComponent("fusion-live-login",isDirectory:true)
let qr=URL(fileURLWithPath:workspace).appendingPathComponent("login-qr/ios-bili-qr.png")
let keyFile=privateFolder.appendingPathComponent("challenge.json"),sessionFile=privateFolder.appendingPathComponent("session.json")
try FileManager.default.createDirectory(at:privateFolder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
let config=URLSessionConfiguration.ephemeral;config.httpCookieStorage=nil;config.httpShouldSetCookies=false;config.urlCache=nil
let session=URLSession(configuration:config)
func request(_ path:String)async throws->([String:Any],HTTPURLResponse){
    var req=URLRequest(url:URL(string:"https://passport.bilibili.com"+path)!)
    req.timeoutInterval=20;req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/130.0.0.0 Safari/537.36",forHTTPHeaderField:"User-Agent")
    req.setValue("https://www.bilibili.com/",forHTTPHeaderField:"Referer")
    let (bytes,response)=try await session.data(for:req)
    guard bytes.count<65536,let response=response as? HTTPURLResponse,response.url?.host=="passport.bilibili.com",response.statusCode==200,let body=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],body["code"] as? Int==0,let data=body["data"] as? [String:Any] else{throw LoginFailure(message:"Official login request was not confirmed")}
    return(data,response)
}
func save(_ object:Any,_ url:URL)throws{
    try JSONSerialization.data(withJSONObject:object).write(to:url,options:.atomic)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
}
do{
    if mode=="generate"{
        let (data,_)=try await request("/x/passport-login/web/qrcode/generate")
        guard let key=data["qrcode_key"] as? String,key.range(of:"^[A-Za-z0-9_-]{16,128}$",options:.regularExpression) != nil,let text=data["url"] as? String,let url=URL(string:text),url.scheme=="https",["passport.bilibili.com","account.bilibili.com"].contains(url.host ?? ""),url.user==nil,url.password==nil,url.port==nil || url.port==443 else{throw LoginFailure(message:"Official QR address invalid")}
        let filter=CIFilter.qrCodeGenerator();filter.message=Data(text.utf8);filter.correctionLevel="M"
        guard let output=filter.outputImage else{throw LoginFailure(message:"QR generation failed")}
        let input=output.composited(over:CIImage(color:CIColor.white)).cropped(to:output.extent.insetBy(dx:-4,dy:-4))
        guard let cg=CIContext().createCGImage(input.transformed(by:CGAffineTransform(scaleX:8,y:8)),from:input.extent.applying(CGAffineTransform(scaleX:8,y:8))) else{throw LoginFailure(message:"QR image creation failed")}
        let bitmap=NSBitmapImageRep(cgImage:cg)
        guard let png=bitmap.representation(using:.png,properties:[:]) else{throw LoginFailure(message:"QR image encoding failed")}
        try FileManager.default.createDirectory(at:qr.deletingLastPathComponent(),withIntermediateDirectories:true)
        try png.write(to:qr,options:.atomic);try save(["key":key],keyFile)
        print("IOS_BILI_LOGIN_QR_READY")
    }else if mode=="poll"{
        let stored=try JSONSerialization.jsonObject(with:Data(contentsOf:keyFile)) as? [String:String]
        guard let key=stored?["key"] else{throw LoginFailure(message:"No pending login")}
        defer{try? FileManager.default.removeItem(at:keyFile)}
        let deadline=Date().addingTimeInterval(190);var confirmed=false
        while Date()<deadline{
            let (data,response)=try await request("/x/passport-login/web/qrcode/poll?qrcode_key="+key)
            let code=data["code"] as? Int ?? -1
            if code==0{
                let headers=response.allHeaderFields.reduce(into:[String:String]()){if let k=$1.key as? String,let v=$1.value as? String{$0[k]=v}}
                let cookies=HTTPCookie.cookies(withResponseHeaderFields:headers,for:URL(string:"https://passport.bilibili.com")!).filter{c in c.domain.trimmingCharacters(in:CharacterSet(charactersIn:"."))=="bilibili.com" && c.isSecure && c.path=="/" && (c.expiresDate==nil || c.expiresDate!>Date())}
                guard cookies.contains(where:{$0.name=="SESSDATA"}) else{throw LoginFailure(message:"Confirmed login did not return a usable session")}
                try save(cookies.map{c->[String:Any] in var row:[String:Any]=["name":c.name,"value":c.value,"domain":c.domain,"path":c.path,"secure":true];if let expires=c.expiresDate{row["expires"]=expires.timeIntervalSince1970};return row},sessionFile)
                confirmed=true;print("IOS_BILI_LOGIN_CONFIRMED: temporary session saved without logging credentials");break
            }
            guard code==86101 || code==86090 else{throw LoginFailure(message:code==86038 ? "QR expired; explicitly request a fresh login run":"Login was not confirmed")}
            try await Task.sleep(nanoseconds:2_000_000_000)
        }
        guard confirmed else{throw LoginFailure(message:"Timed out waiting for user QR confirmation")}
    }else{throw LoginFailure(message:"Unknown login mode")}
}catch{
    // Never print raw errors: URLSession error dictionaries can contain the pending QR key.
    fputs("Explicit iOS cloud login failed or expired; no secrets were logged.\n",stderr);exit(1)
}
