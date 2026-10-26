import Foundation

/// Slow platform metadata must not consume the slots needed to play/pause existing media.
/// Both lanes remain bounded; this never retries, reopens or resolves a live stream.
struct BridgeBudget {
    enum Lane:Equatable { case network, playback }
    private(set) var network=0,playback=0
    private let networkLimit=16,playbackLimit=16
    static let controls:Set<String>=["mediaOpen","mediaPlay","mediaPause","mediaSeek","mediaVolume","mediaAudioOnly","mediaClose","mediaVoice","fullscreen","orientation","backgroundMode","playbackState","pipStart","pipStop","pipPause","videoPiPStart","videoPiP","videoPiPStop"]
    mutating func acquire(_ operation:String)->Lane? {
        if Self.controls.contains(operation){
            guard playback<playbackLimit else{return nil};playback += 1;return .playback
        }
        guard network<networkLimit else{return nil};network += 1;return .network
    }
    mutating func release(_ lane:Lane){
        switch lane{case .network:network=max(0,network-1);case .playback:playback=max(0,playback-1)}
    }
}
