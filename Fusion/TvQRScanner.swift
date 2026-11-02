import UIKit
import AVFoundation

enum TvPairCode {
 static func decode(_ text:String)throws->JSON {
  guard text.count<=240,let u=URLComponents(string:text),u.scheme=="bilifusion",u.host=="tv-pair",u.user==nil,u.password==nil,u.port==nil,u.path.isEmpty,u.fragment==nil,let items=u.queryItems,items.count==3 else{throw FusionError("请扫描二路随行电视接收端的连接二维码")}
  var fields=[String:String]();for item in items{guard fields[item.name]==nil,let value=item.value else{throw FusionError("连接二维码有重复字段")};fields[item.name]=value}
  guard fields["v"]=="1",let address=fields["address"],address.range(of:"^[0-9.]+:[0-9]{4,5}$",options:.regularExpression) != nil,let pin=fields["pin"],pin.range(of:"^[0-9]{6}$",options:.regularExpression) != nil else{throw FusionError("电视连接二维码格式无效")}
  _ = try TvTransport.address(address);return ["address":address,"pin":pin]
 }
}

@MainActor final class TvQRScanner:UIViewController,AVCaptureMetadataOutputObjectsDelegate {
 private let session=AVCaptureSession(),queue=DispatchQueue(label:"fusion.tv.qr.camera"),label=UILabel()
 private var layer:AVCaptureVideoPreviewLayer?,finished=false,completion:((JSON)->Void)?
 static func scan(from host:UIViewController)async throws->JSON {
  guard host.presentedViewController==nil else{throw FusionError("请先关闭当前窗口")}
  let allowed=AVCaptureDevice.authorizationStatus(for:.video)==.authorized ? true:await AVCaptureDevice.requestAccess(for:.video)
  guard allowed else{throw FusionError("未允许相机，可在电视投屏中手动输入地址和配对码")}
  return await withCheckedContinuation{continuation in let scanner=TvQRScanner();scanner.modalPresentationStyle = .fullScreen;scanner.completion={continuation.resume(returning:$0)};host.present(scanner,animated:true)}
 }
 override func viewDidLoad(){super.viewDidLoad();view.backgroundColor = .black;label.text="扫描电视上的连接二维码\n仅在本机识别";label.textColor = .white;label.numberOfLines=0;label.textAlignment = .center;view.addSubview(label);let cancel=UIButton(type:.system);cancel.setTitle("取消扫码",for:.normal);cancel.addTarget(self,action:#selector(cancelScan),for:.touchUpInside);cancel.tag=73;view.addSubview(cancel)
  do{guard let camera=AVCaptureDevice.default(for:.video) else{throw FusionError("设备没有可用相机")};let input=try AVCaptureDeviceInput(device:camera);let output=AVCaptureMetadataOutput();guard session.canAddInput(input),session.canAddOutput(output) else{throw FusionError("相机暂不可用")};session.beginConfiguration();session.sessionPreset = .medium;session.addInput(input);session.addOutput(output);output.setMetadataObjectsDelegate(self,queue:.main);output.metadataObjectTypes=[.qr];session.commitConfiguration();let preview=AVCaptureVideoPreviewLayer(session:session);preview.videoGravity = .resizeAspectFill;view.layer.insertSublayer(preview,at:0);layer=preview;queue.async{[session] in session.startRunning()}}
  catch{label.text="相机暂不可用，请返回后手动输入电视地址和配对码。"}
 }
 override func viewDidLayoutSubviews(){super.viewDidLayoutSubviews();layer?.frame=view.bounds;let safe=view.safeAreaInsets;label.frame=CGRect(x:12,y:safe.top+16,width:view.bounds.width-24,height:80);view.viewWithTag(73)?.frame=CGRect(x:24,y:view.bounds.height-safe.bottom-64,width:view.bounds.width-48,height:48)}
 override func viewDidDisappear(_ animated:Bool){super.viewDidDisappear(animated);if !finished{finish(["cancelled":true])}}
 @objc private func cancelScan(){finish(["cancelled":true])}
 private func finish(_ value:JSON){guard !finished else{return};finished=true;queue.async{[session] in session.stopRunning()};let done=completion;completion=nil;dismiss(animated:true){done?(value)}}
 func metadataOutput(_ output:AVCaptureMetadataOutput,didOutput objects:[AVMetadataObject],from connection:AVCaptureConnection){guard !finished else{return};for case let object as AVMetadataMachineReadableCodeObject in objects{if let text=object.stringValue,let pair=try? TvPairCode.decode(text){finish(pair);return}}}
}
