import UIKit
import AVKit
import CoreMedia
import CoreVideo
import ImageIO

final class MessageSurface: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    override init(frame: CGRect) { super.init(frame: frame); isUserInteractionEnabled = false; backgroundColor = .black; displayLayer.videoGravity = .resizeAspect }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Genuine sample-buffer PiP. No private APIs, transparent window hacks, or silent keep-alive audio.
@MainActor final class MessagePictureInPicture: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    let surface = MessageSurface(frame: .zero)
    private(set) var enabled = false
    private(set) var active = false
    private(set) var paused = false
    private var controller: AVPictureInPictureController?
    private var startTask: Task<Void, Never>?, ticker: Timer?
    private var images = [URL: UIImage](), loading = Set<URL>(), attempted = Set<URL>(), imageGeneration = 0
    private var room = "", title = "二路消息", connection = "等待消息连接"
    private var store = PiPMessageStore()
    var clock: () -> (time: Double, edge: Double?, paused: Bool, ready: Bool) = { (0,nil,true,false) }
    var onState: (String, String) -> Void = { _,_ in }
    var onPlaying: (Bool) -> Void = { _ in }
    var onRestore: () -> Void = {}
    var rows = 5, showChat = true, showSC = true, showUser = true
    var fontSize: CGFloat = 32
    var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var modelCount: Int { store.items.count }
    var renderedFrames = 0
    override init() {
        super.init()
        surface.isHidden = true
        var base: CMTimebase?
        if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &base) == noErr, let base {
            CMTimebaseSetTime(base, time: CMClockGetTime(CMClockGetHostTimeClock())); CMTimebaseSetRate(base, rate: 1)
            surface.displayLayer.controlTimebase = base
        }
    }
    func selectRoom(_ id: String, title: String, platform:String="bilibili") {
        self.title = String(title.prefix(60))
        if room != platform+":"+id { room = platform+":"+id; store = PiPMessageStore(); images.removeAll(); attempted.removeAll(); loading.removeAll(); imageGeneration += 1 }
        store.platform=platform
    }
    func learn(_ data: Any) { store.learn(data) }
    func setBlocking(_ rules: JSON) { store.setBlocking(rules); render() }
    func receive(_ event: JSON) {
        if !event.str("status").isEmpty { connection = String(event.str("status").prefix(100)) }
        if let packet = event["packet"] as? JSON { store.receive(packet, edge: clock().edge) }
    }
    func configure(_ args: JSON) {
        store.mergeSame=args["mergeSame"] as? Bool ?? false
        rows = max(2,min(8,args.int("rows") == 0 ? 5 : args.int("rows")))
        showChat = args["chat"] as? Bool ?? true; showSC = args["sc"] as? Bool ?? true; showUser = args["user"] as? Bool ?? true
        fontSize = CGFloat(max(24,min(44,args.int("size") == 0 ? 32 : args.int("size"))))
    }
    func start(in parent: UIView) throws {
        store.setBlocking(BlockRules.load())
        guard supported else { throw FusionError("当前设备不支持系统画中画") }
        guard !enabled else { return }
        guard clock().ready else { throw FusionError("请等待二路声音开始播放后，再开启消息画中画") }
        enabled = true; paused = false; surface.isHidden = false
        if surface.superview !== parent { surface.removeFromSuperview(); parent.addSubview(surface) }
        layout(in: parent)
        if controller == nil {
            let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: surface.displayLayer, playbackDelegate: self)
            controller = AVPictureInPictureController(contentSource: source)
            controller?.delegate = self; controller?.requiresLinearPlayback = true
            controller?.canStartPictureInPictureAutomaticallyFromInline = false
        }
        render()
        ticker?.invalidate(); ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.render() } }
        onState("starting", "正在打开二路消息画中画…")
        startTask = Task { [weak self] in
            // The source must have a visible, primed display layer before AVKit permits PiP.
            for _ in 0..<40 {
                do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                guard let self, self.enabled else { return }
                if self.controller?.isPictureInPicturePossible == true {
                    self.controller?.startPictureInPicture()
                    do { try await Task.sleep(nanoseconds: 8_000_000_000) } catch { return }
                    if self.enabled && !self.active { self.finish(error:"系统画中画未完成启动，请返回 App 重试") }
                    return
                }
            }
            self?.finish(error: "系统当前无法开启画中画。请先保持 App 在前台，并检查系统画中画设置后重试。")
        }
    }
    func layout(in parent: UIView) {
        let safe = parent.safeAreaLayoutGuide.layoutFrame
        let width = min(280,max(160,safe.width*0.45)), height = width*2/3
        surface.frame = CGRect(x: max(safe.minX,safe.maxX-width-12), y: max(safe.minY,safe.minY+12), width: width,height:height)
    }
    func stop() {
        startTask?.cancel()
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        else { finish() }
    }
    private func finish(error: String? = nil) {
        guard enabled || active else { return }
        enabled = false; active = false; startTask?.cancel(); startTask = nil; ticker?.invalidate(); ticker = nil
        surface.isHidden = true; surface.removeFromSuperview(); surface.displayLayer.flushAndRemoveImage()
        onState(error == nil ? "stopped" : "error", error ?? "已关闭消息画中画")
    }
    func setPaused(_ value: Bool) {
        paused = value
        if value { store.clearMessages() }
        controller?.invalidatePlaybackState(); render()
    }
    private func requestImages(_ messages: [PiPMessage]) {
        for url in messages.flatMap(\.parts).compactMap(\.image) {
            guard images[url] == nil, !attempted.contains(url), loading.count < 2 else { continue }
            if attempted.count >= 256 { attempted.removeAll() }
            attempted.insert(url); loading.insert(url); let generation = imageGeneration
            Task { [weak self] in
                var image: UIImage?
                var request = URLRequest(url: url); request.setValue(Safety.ua,forHTTPHeaderField:"User-Agent")
                if let (data,response) = try? await HTTP.shared.fetch(request,limit:1024*1024), response.statusCode == 200,
                   response.mimeType?.hasPrefix("image/") == true,
                   let source = CGImageSourceCreateWithData(data as CFData,nil),
                   let thumb = CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:128] as CFDictionary) {
                    image = UIImage(cgImage:thumb)
                }
                guard let self, self.imageGeneration == generation else { return }
                self.loading.remove(url)
                if let image { if self.images.count >= 64 { self.images.removeAll() }; self.images[url] = image }
            }
        }
    }
    func render() {
        guard enabled else { return }
        let playback = clock(), hidden = paused || playback.paused
        let messages = hidden ? [] : store.visible(time: playback.time, edge: playback.edge, rows: rows, chat: showChat, sc: showSC)
        requestImages(messages)
        let state = hidden ? "已暂停 · 画面消息已清空" : !playback.ready ? "二路音频正在缓冲…" : connection
        let frame = Self.draw(messages, title:title, status:state, paused:hidden, rows:rows, showUser:showUser,fontSize:fontSize,images:images)
        if let sample = Self.sample(frame) {
            if surface.displayLayer.status == .failed { surface.displayLayer.flush() }
            if surface.displayLayer.isReadyForMoreMediaData { surface.displayLayer.enqueue(sample); renderedFrames += 1 }
        }
    }
    static func draw(_ messages: [PiPMessage], title: String, status: String, paused: Bool, rows: Int = 5, showUser: Bool = true, fontSize: CGFloat = 32, images: [URL:UIImage] = [:]) -> UIImage {
        let size = CGSize(width: 960,height:640), format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size:size,format:format).image { context in
            UIColor(red:0.045,green:0.075,blue:0.12,alpha:1).setFill(); context.fill(CGRect(origin:.zero,size:size))
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(in:CGRect(x:24,y:16,width:910,height:38),withAttributes:[.font:UIFont.boldSystemFont(ofSize:28),.foregroundColor:UIColor.white,.paragraphStyle:paragraph])
            (status as NSString).draw(in:CGRect(x:24,y:57,width:910,height:34),withAttributes:[.font:UIFont.systemFont(ofSize:22),.foregroundColor:UIColor(red:0.4,green:0.85,blue:0.94,alpha:1),.paragraphStyle:paragraph])
            if messages.isEmpty {
                ((paused ? "继续播放后显示新消息" : "等待二路弹幕 / SC…") as NSString).draw(in:CGRect(x:28,y:280,width:900,height:90),withAttributes:[.font:UIFont.systemFont(ofSize:32),.foregroundColor:UIColor.lightGray])
                return
            }
            let height = floor(520/CGFloat(max(2,min(8,rows))))
            for (i,message) in messages.prefix(8).enumerated() {
                let box = CGRect(x:16,y:100+CGFloat(i)*height,width:928,height:height-7)
                (message.price == nil ? UIColor(white:1,alpha:0.05) : UIColor(red:0.10,green:0.31,blue:0.43,alpha:1)).setFill()
                UIBezierPath(roundedRect:box,cornerRadius:10).fill()
                let line = NSMutableAttributedString(string:"")
                if showUser || message.price != nil {
                    let name = message.user.isEmpty ? "观众" : message.user
                    let suffix = message.price.map { " · ¥\($0)" } ?? ""
                    line.append(NSAttributedString(string:name+suffix+"：",attributes:[.foregroundColor:UIColor(red:0.65,green:0.78,blue:1,alpha:1),.font:UIFont.boldSystemFont(ofSize:fontSize)]))
                }
                for part in message.parts {
                    if let url = part.image, let image = images[url] {
                        let attachment = NSTextAttachment(); attachment.image = image
                        attachment.bounds = CGRect(x:0,y:-6,width:fontSize*CGFloat(part.ratio)*1.25,height:fontSize*1.25)
                        line.append(NSAttributedString(attachment:attachment))
                    } else { line.append(NSAttributedString(string:part.text,attributes:[.font:UIFont.systemFont(ofSize:fontSize),.foregroundColor:UIColor.white])) }
                }
                if message.mergeCount>1 {line.append(NSAttributedString(string:" ×\(message.mergeCount)",attributes:[.font:UIFont.boldSystemFont(ofSize:fontSize * 0.8),.foregroundColor:UIColor.cyan]))}
                // Core Text truncates at the fixed row bounds; one message cannot cover the next.
                let body = box.insetBy(dx:12,dy:8)
                line.draw(with:body,options:[.usesLineFragmentOrigin,.truncatesLastVisibleLine],context:nil)
            }
        }
    }
    static func sample(_ image: UIImage) -> CMSampleBuffer? {
        guard let cg = image.cgImage else { return nil }
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey:true,kCVPixelBufferCGBitmapContextCompatibilityKey:true,kCVPixelBufferIOSurfacePropertiesKey:[:] as [String:Any]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault,cg.width,cg.height,kCVPixelFormatType_32BGRA,attributes,&buffer) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer,[]); defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
        guard let canvas = CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:cg.width,height:cg.height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        canvas.draw(cg,in:CGRect(x:0,y:0,width:cg.width,height:cg.height))
        var description: CMVideoFormatDescription?, sample: CMSampleBuffer?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:buffer,formatDescriptionOut:&description) == noErr, let description else { return nil }
        var timing = CMSampleTimingInfo(duration:CMTime(value:1,timescale:2),presentationTimeStamp:CMClockGetTime(CMClockGetHostTimeClock()),decodeTimeStamp:.invalid)
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:buffer,formatDescription:description,sampleTiming:&timing,sampleBufferOut:&sample) == noErr else { return nil }
        return sample
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) { setPaused(!playing); onPlaying(playing) }
    func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange { CMTimeRange(start:.zero,duration:.positiveInfinity) }
    func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { paused || clock().paused }
    func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) { render() }
    func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) { completionHandler() }
    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) { guard enabled else { controller.stopPictureInPicture(); return }; active = true; startTask?.cancel(); onState("active","消息画中画已开启，可以切到其他视频 App") }
    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { finish(error:"画中画启动失败（\((error as NSError).code)），请保持 App 在前台后重试") }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) { finish() }
    func pictureInPictureController(_ controller: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) { onRestore(); completionHandler(true) }
    deinit { startTask?.cancel(); ticker?.invalidate() }
}
