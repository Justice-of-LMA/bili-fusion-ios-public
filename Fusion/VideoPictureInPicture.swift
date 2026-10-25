import UIKit
import AVKit

/// One explicit native AVPlayerLayer PiP. It reuses the existing item and never opens a URL.
/// This system video window cannot include the transparent WKWebView's danmaku/SC layer.
@MainActor final class VideoPictureInPicture:NSObject,AVPictureInPictureControllerDelegate {
    private(set) var enabled=false,active=false,armed=false,source=""
    private var controller:AVPictureInPictureController?
    private weak var native:NativePlayer?
    private var startTask:Task<Void,Never>?
    var onState:(String,String)->Void={_,_ in}
    var onRestore:()->Void={}
    var supported:Bool{AVPictureInPictureController.isPictureInPictureSupported()}
    func prepareAutomatic(_ player:NativePlayer,source:String)throws{
        guard supported else{throw FusionError("当前设备不支持系统视频画中画")}
        guard !player.token.isEmpty,player.player.currentItem != nil else{return}
        guard !enabled else{return}
        if self.native !== player || controller==nil{
            controller?.delegate=nil;controller=AVPictureInPictureController(playerLayer:player.surface.videoLayer);controller?.delegate=self
        }
        guard let controller else{throw FusionError("系统未能准备自动视频小窗")}
        native=player;self.source=source;armed=true;controller.requiresLinearPlayback=true;controller.canStartPictureInPictureAutomaticallyFromInline=true
    }
    func disarmAutomatic(){armed=false;controller?.canStartPictureInPictureAutomaticallyFromInline=false;if !enabled{controller?.delegate=nil;controller=nil;native=nil;source=""}}
    func start(_ player:NativePlayer,source:String)throws{
        guard supported else{throw FusionError("当前设备不支持系统视频画中画")}
        guard !player.token.isEmpty,player.player.currentItem != nil,!player.isAudioOnly,!player.surface.isHidden,player.surface.videoLayer.isReadyForDisplay else{throw FusionError("请先播放可见的 HLS 视频，再开启视频小窗；仅音频或网页 FLV 不支持此原生小窗")}
        guard !enabled else{if self.source==source{return};throw FusionError("请先关闭当前视频小窗，再切换 A / B")}
        let pip:AVPictureInPictureController
        if native === player,let current=controller{pip=current}
        else{guard let created=AVPictureInPictureController(playerLayer:player.surface.videoLayer) else{throw FusionError("系统未能建立视频画中画")};controller?.delegate=nil;pip=created}
        enabled=true;active=false;self.source=source;native=player;controller=pip
        pip.delegate=self;pip.requiresLinearPlayback=true;pip.canStartPictureInPictureAutomaticallyFromInline=armed
        player.setPictureInPicture(true)
        onState("starting","正在打开 \(source) 视频小窗…")
        startTask=Task{[weak self] in
            for _ in 0..<40{
                guard let self,self.enabled else{return}
                if self.controller?.isPictureInPicturePossible==true{
                    self.controller?.startPictureInPicture()
                    do{try await Task.sleep(nanoseconds:8_000_000_000)}catch{return}
                    if self.enabled && !self.active{self.finish("系统视频画中画未完成启动，请保持前台后手动重试")};return
                }
                do{try await Task.sleep(nanoseconds:200_000_000)}catch{return}
            }
            self?.finish("系统当前不允许视频画中画，请核对系统设置、房间线路与视频是否已开始")
        }
    }
    func stop(){startTask?.cancel();if controller?.isPictureInPictureActive==true{controller?.stopPictureInPicture()}else{finish()}}
    private func finish(_ error:String?=nil){
        guard enabled||armed||controller != nil else{return}
        startTask?.cancel();startTask=nil;enabled=false;active=false;armed=false
        let old=controller;controller=nil;old?.delegate=nil;if old?.isPictureInPictureActive==true{old?.stopPictureInPicture()}
        native?.setPictureInPicture(false);native=nil;source=""
        onState(error==nil ? "stopped":"error",error ?? "视频小窗已关闭，原直播未刷新")
    }
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController:AVPictureInPictureController){guard enabled||armed else{return};enabled=true;native?.setPictureInPicture(true);onState("starting","正在打开系统视频小窗…")}
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController:AVPictureInPictureController){guard enabled||armed else{pictureInPictureController.stopPictureInPicture();return};enabled=true;active=true;startTask?.cancel();onState("active","系统视频小窗已开启；弹幕 / SC 仍在 App 内，需消息列表时请切换消息画中画")}
    func pictureInPictureController(_ pictureInPictureController:AVPictureInPictureController,failedToStartPictureInPictureWithError error:Error){finish("系统视频小窗启动失败（\((error as NSError).code)），原直播未刷新")}
    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController:AVPictureInPictureController){finish()}
    func pictureInPictureController(_ pictureInPictureController:AVPictureInPictureController,restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:@escaping(Bool)->Void){onRestore();completionHandler(true)}
    deinit{startTask?.cancel()}
}
