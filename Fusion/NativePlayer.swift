import UIKit
import AVFoundation

final class VideoSurface: UIView {
    let videoLayer=AVPlayerLayer()
    private(set) var videoScale:CGFloat=1,videoX:CGFloat=0,videoY:CGFloat=0
    override init(frame:CGRect){super.init(frame:frame);backgroundColor = .black;clipsToBounds=true;isUserInteractionEnabled=false;layer.addSublayer(videoLayer);videoLayer.videoGravity = .resizeAspect}
    required init?(coder:NSCoder){fatalError("init(coder:) has not been implemented")}
    func zoom(scale:CGFloat,x:CGFloat,y:CGFloat){videoScale=max(1,min(4,scale.isFinite ? scale:1));videoX=x.isFinite ? x:0;videoY=y.isFinite ? y:0;setNeedsLayout();layoutIfNeeded()}
    override func layoutSubviews(){super.layoutSubviews();CATransaction.begin();CATransaction.setDisableActions(true);videoLayer.setAffineTransform(.identity);videoLayer.bounds=CGRect(origin:.zero,size:bounds.size);videoX=max(-bounds.width*(videoScale-1)/2,min(bounds.width*(videoScale-1)/2,videoX));videoY=max(-bounds.height*(videoScale-1)/2,min(bounds.height*(videoScale-1)/2,videoY));videoLayer.position=CGPoint(x:bounds.midX+videoX,y:bounds.midY+videoY);videoLayer.setAffineTransform(CGAffineTransform(scaleX:videoScale,y:videoScale));CATransaction.commit()}
}
@MainActor final class NativePlayer {
    let surface = VideoSurface(frame: .zero)
    let player = AVPlayer()
    var token = ""
    private var desiredPaused = true, seeking = false, seekRevision = 0
    private var seekWaiter: CheckedContinuation<Void, Error>?, seekTimeout: Task<Void, Never>?
    var seekDeadline: UInt64 = 6_000_000_000
    var seekDriver: ((AVPlayer, CMTime, @escaping (Bool) -> Void) -> Void)?
    private var audioOnly = false
    private var backgrounded = false, backgroundAudio = true, presentingPiP = false
    private var interruptionBlocked = false, accountBlocked = false, routeBlocked = false,messageBlocked=false
    var isAudioOnly:Bool{audioOnly}
    var wantsPlayback: Bool { !desiredPaused && !token.isEmpty }
    var mayResume:Bool{wantsPlayback && !interruptionBlocked && !accountBlocked && !routeBlocked && !messageBlocked}
    var systemAllowsPlayback:Bool{!interruptionBlocked && !routeBlocked}
    var isSuspended: Bool { interruptionBlocked || accountBlocked || routeBlocked || messageBlocked || (backgrounded && !backgroundAudio && !presentingPiP) }
    private var tracksObserver: NSKeyValueObservation?
    private var bufferObservers=[NSKeyValueObservation](),itemNotifications=[NSObjectProtocol]()
    private var lastTransportError:JSON=[:]
    private var ended=false,terminalFailure="",lastRecoveryPosition = -Double.infinity,lastRecoveryEnd = -Double.infinity
    private(set) var bufferRecoveries=0,playRequests=0,stallEvents=0
    init() { surface.videoLayer.player = player; player.automaticallyWaitsToMinimizeStalling = true; player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible; surface.isHidden = true }
    deinit { itemNotifications.forEach { NotificationCenter.default.removeObserver($0) } }
    func open(url: URL, token: String, volume: Float, audioOnly: Bool = false) {
        close(); self.token = token; self.audioOnly = audioOnly
        let item = AVPlayerItem(url: url)
        // Let AVFoundation adapt its forward buffering to the actual HLS throughput. This
        // is not a promise of 20 seconds of retained history; seeking still uses loaded ranges.
        item.preferredForwardBufferDuration = 0
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        player.volume = max(0, min(1, volume)); player.replaceCurrentItem(with: item)
        watchBuffer(\.status,item);watchBuffer(\.loadedTimeRanges,item);watchBuffer(\.isPlaybackBufferEmpty,item);watchBuffer(\.isPlaybackLikelyToKeepUp,item);watchBuffer(\.isPlaybackBufferFull,item)
        for name in [AVPlayerItem.playbackStalledNotification,AVPlayerItem.didPlayToEndTimeNotification,AVPlayerItem.failedToPlayToEndTimeNotification]{
            itemNotifications.append(NotificationCenter.default.addObserver(forName:name,object:item,queue:.main){[weak self,weak item] notification in Task{@MainActor in
                guard let self,let item,self.player.currentItem === item,!self.token.isEmpty else{return}
                if name==AVPlayerItem.didPlayToEndTimeNotification{self.ended=true}
                else if name==AVPlayerItem.failedToPlayToEndTimeNotification{
                    if let error=notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError{self.lastTransportError=["domain":error.domain,"code":error.code,"underlyingCode":(error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0]}
                    // A live rendition can report a failed end while the item remains
                    // ready and AVFoundation is still obtaining its next media data.
                    // Only .failed is terminal; do not make a ready/waiting item a user pause.
                    if item.status == .failed{self.terminalFailure="直播播放失败，请手动重新获取；未自动刷新"}
                    else{self.bufferedDataChanged(item)}
                }
                else{self.stallEvents += 1;self.bufferedDataChanged(item)}
            }})
        }
        reconnectPresentation()
        tracksObserver = item.observe(\.tracks, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.applyTrackMode() }
        }
    }
    func setAudioOnly(_ value: Bool) { audioOnly = value; applyTrackMode() }
    private func applyTrackMode() {
        for track in player.currentItem?.tracks ?? [] where track.assetTrack?.mediaType == .video { track.isEnabled = !audioOnly }
    }
    func play() { desiredPaused = false; interruptionBlocked=false;routeBlocked=false;resumeIfAllowed() }
    func pause() { desiredPaused = true; player.pause() }
    private func resumeIfAllowed(){
        if isSuspended||desiredPaused{if player.timeControlStatus != .paused{player.pause()};return}
        guard !seeking,!token.isEmpty,!ended,terminalFailure.isEmpty,let item=player.currentItem,item.status != .failed else{return}
        // A waiting player already has a play request. Reissuing playImmediately repeatedly
        // defeats adaptive waiting and turns a short network gap into another empty-buffer stop.
        if player.timeControlStatus == .paused{playRequests += 1;player.play()}
    }
    private func watchBuffer<Value>(_ keyPath:KeyPath<AVPlayerItem,Value>,_ item:AVPlayerItem){
        bufferObservers.append(item.observe(keyPath,options:[.initial,.new]){[weak self,weak item] _,_ in Task{@MainActor in if let item{self?.bufferedDataChanged(item)}}})
    }
    private func bufferedDataChanged(_ item:AVPlayerItem){
        guard player.currentItem === item,!token.isEmpty,!desiredPaused,!seeking,!isSuspended,!ended,terminalFailure.isEmpty,item.status == .readyToPlay,player.timeControlStatus == .paused,!item.isPlaybackBufferEmpty else{return}
        let position=player.currentTime().seconds
        guard position.isFinite,let end=ranges(item.loadedTimeRanges).filter({position >= $0[0]-0.05 && $0[1]-position >= 0.15}).map({$0[1]}).max() else{return}
        // An event-only safety net for a paused transport with real data (for example a
        // file-backed/local proxy item). No polling, new item, URL, seek, or live-edge correction.
        guard position>lastRecoveryPosition+0.05 || end>lastRecoveryEnd+0.05 else{return}
        lastRecoveryPosition=position;lastRecoveryEnd=end;bufferRecoveries += 1;resumeIfAllowed()
    }
    // Lifecycle pauses are not user pauses. Preserve this player/item/token and buffered clock;
    // never replace the item, jump to live, or fetch another room to repair presentation.
    func enterBackground(continueAudio:Bool,keepVideoForPiP:Bool=false){backgrounded=true;backgroundAudio=continueAudio;presentingPiP=keepVideoForPiP;reconnectPresentation();resumeIfAllowed()}
    func enterForeground(){backgrounded=false;reconnectPresentation();resumeIfAllowed()}
    func setPictureInPicture(_ active:Bool){presentingPiP=active;reconnectPresentation();resumeIfAllowed()}
    private func reconnectPresentation(){
        if backgrounded && !presentingPiP {surface.videoLayer.player=nil}
        else {if surface.videoLayer.player !== player{surface.videoLayer.player=player};surface.setNeedsLayout();surface.setNeedsDisplay()}
    }
    func interruptionBegan(){interruptionBlocked=true;player.pause()}
    func interruptionEnded(shouldResume:Bool){interruptionBlocked = !shouldResume;resumeIfAllowed()}
    func suspendForAccount(_ suspended:Bool){accountBlocked=suspended;resumeIfAllowed()}
    func setMessagePiPOnly(_ suspended:Bool){messageBlocked=suspended;resumeIfAllowed()}
    func routeDisconnected(){routeBlocked=true;player.pause()}
    func close() { surface.zoom(scale:1,x:0,y:0);tracksObserver?.invalidate();tracksObserver=nil;bufferObservers.forEach{$0.invalidate()};bufferObservers.removeAll();itemNotifications.forEach{NotificationCenter.default.removeObserver($0)};itemNotifications.removeAll();finishSeek(.failure(FusionError("播放已关闭")));seekRevision += 1;seeking=false;token="";desiredPaused=true;interruptionBlocked=false;accountBlocked=false;routeBlocked=false;messageBlocked=false;presentingPiP=false;ended=false;terminalFailure="";lastTransportError=[:];lastRecoveryPosition = -Double.infinity;lastRecoveryEnd = -Double.infinity;bufferRecoveries=0;playRequests=0;stallEvents=0;player.pause();player.replaceCurrentItem(with:nil);surface.isHidden=true }
    private func ranges(_ values: [NSValue]) -> [[Double]] {
        values.compactMap { value in
            let range = value.timeRangeValue, start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
            return start.isFinite && end.isFinite && end > start ? [start, end] : nil
        }
    }
    private func finishSeek(_ result: Result<Void, Error>) {
        seekTimeout?.cancel(); seekTimeout=nil; seeking=false
        let waiter=seekWaiter; seekWaiter=nil; waiter?.resume(with:result)
    }
    func seek(_ target: Double) async throws {
        guard target.isFinite, target >= 0, let item = player.currentItem else { throw FusionError("播放位置无效") }
        let spans = ranges(item.loadedTimeRanges)
        guard spans.contains(where: { target >= $0[0] && target <= $0[1] }) else { throw FusionError("该位置已超出可用缓存，请回到直播后重新对齐") }
        finishSeek(.failure(FusionError("已被新的跳转操作取代")))
        seekRevision += 1; let revision = seekRevision; seeking = true
        item.cancelPendingSeeks()
        player.pause()
        try await withCheckedThrowingContinuation { (waiter:CheckedContinuation<Void,Error>) in
            seekWaiter=waiter
            seekTimeout=Task { [weak self] in
                do {try await Task.sleep(nanoseconds:self?.seekDeadline ?? 6_000_000_000)} catch{return}
                guard let self,self.seekRevision==revision,self.seeking else{return}
                self.seekRevision += 1;item.cancelPendingSeeks();self.desiredPaused=true;self.player.pause()
                self.finishSeek(.failure(FusionError("缓存跳转超时；未刷新直播，请点继续或重新调整")))
            }
            let complete:(Bool)->Void = { [weak self] finished in
                Task { @MainActor in
                    guard let self,self.seekRevision==revision,self.seeking else{return}
                    if finished {self.finishSeek(.success(()));self.resumeIfAllowed()}
                    else {self.desiredPaused=true;self.player.pause();self.finishSeek(.failure(FusionError("缓存跳转未完成；请重新调整")))}
                }
            }
            let time=CMTime(seconds:target,preferredTimescale:600)
            if let driver=seekDriver {driver(player,time,complete)}
            else {player.seek(to:time,toleranceBefore:CMTime(seconds:0.15,preferredTimescale:600),toleranceAfter:CMTime(seconds:0.15,preferredTimescale:600),completionHandler:complete)}
        }
    }
    static func transportProjection(ready:Bool,control:AVPlayer.TimeControlStatus,requestedRate:Float,desiredPaused:Bool,seeking:Bool,suspended:Bool,bufferedAhead:Double)->(state:Int,rate:Double){
        guard ready else{return(0,0)}
        guard !seeking,!suspended else{return(2,0)}
        if control == .playing && !desiredPaused{return(4,Double(requestedRate))}
        // AVPlayer.rate can be the *requested* rate while waiting; never extrapolate its
        // clock or let the Web message scheduler treat a waiting/paused transport as playing.
        return(desiredPaused && bufferedAhead>0.05 ? 3:2,0)
    }
    func snapshot() -> JSON {
        guard let item = player.currentItem, !token.isEmpty else { return ["token": token, "readyState": 0, "paused": true] }
        let time = player.currentTime().seconds
        let loaded = ranges(item.loadedTimeRanges), seekable = ranges(item.seekableTimeRanges)
        let ahead=loaded.filter{time >= $0[0]-0.05 && time <= $0[1]}.map{$0[1]-time}.max() ?? 0
        let projection=Self.transportProjection(ready:item.status == .readyToPlay,control:player.timeControlStatus,requestedRate:player.rate,desiredPaused:desiredPaused,seeking:seeking,suspended:isSuspended,bufferedAhead:ahead)
        return ["token": token, "currentTime": time.isFinite ? time : 0, "rate": projection.rate, "paused": desiredPaused,
                "seeking": seeking, "suspended":isSuspended,"backgrounded":backgrounded,"readyState": projection.state,"waiting":player.timeControlStatus == .waitingToPlayAtSpecifiedRate,"requestedRate":Double(player.rate),"bufferedAhead":ahead,"stallEvents":stallEvents,"bufferRecoveries":bufferRecoveries,"transportError":lastTransportError,"ranges": loaded, "loaded": loaded, "seekable": seekable,
                "videoWidth": item.presentationSize.width, "videoHeight": item.presentationSize.height,
                "error": item.status == .failed ? "直播解码或网络失败（\((item.error as NSError?)?.code ?? 0)）" : terminalFailure]
    }
}
