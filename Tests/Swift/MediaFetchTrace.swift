import Foundation
import CryptoKit
@testable import Fusion

/// Aggregate media transport facts only: never retain/publish URLs, headers, cookies or bodies.
/// Observes existing AVPlayer requests; does not initiate, retry, refresh or switch a stream.
struct MediaFetchTrace {
    private var pending=[UUID:Double]()
    private var total=0,manifests=0,media=0,failures=0,lastStatus=0
    private var maximumSeconds=0.0,lastManifestSeconds=0.0,maximumAge=0.0
    private var fingerprint=Data(),sameSince=0.0,longestUnchanged=0.0,sameResponses=0
    private var sequence:Int64?
    mutating func begin(now:Double)->UUID{let id=UUID();pending[id]=now;total += 1;return id}
    mutating func finish(_ id:UUID,now:Double,status:Int,isManifest:Bool,body:Data,age:Double=0){
        guard let began=pending.removeValue(forKey:id) else{return}
        let duration=max(0,now-began);maximumSeconds=max(maximumSeconds,duration);lastStatus=status
        if status != 200 && status != 206{failures += 1;return}
        if !isManifest{media += 1;return}
        manifests += 1;lastManifestSeconds=duration;maximumAge=max(maximumAge,age.isFinite ? max(0,age):0)
        let digest=Data(SHA256.hash(data:body))
        if digest==fingerprint{sameResponses += 1;longestUnchanged=max(longestUnchanged,max(0,now-sameSince))}
        else{fingerprint=digest;sameSince=now}
        if let text=String(data:body,encoding:.utf8),let line=text.split(separator:"\n").first(where:{$0.hasPrefix("#EXT-X-MEDIA-SEQUENCE:")}){
            sequence=Int64(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count).trimmingCharacters(in:.whitespacesAndNewlines))
        }
    }
    func snapshot(now:Double)->JSON{
        let mediaSequence:Any
        if let sequence{mediaSequence=sequence}else{mediaSequence=NSNull()}
        return ["requests":total,"pending":pending.count,"oldestPendingSeconds":pending.values.min().map{max(0,now-$0)} ?? 0,
         "manifestResponses":manifests,"mediaResponses":media,"failures":failures,"lastHTTPStatus":lastStatus,
         "maxRequestSeconds":maximumSeconds,"lastManifestRequestSeconds":lastManifestSeconds,
         "largestResponseAgeSeconds":maximumAge,"samePlaylistResponses":sameResponses,
         "longestUnchangedPlaylistSeconds":longestUnchanged,"lastMediaSequence":mediaSequence]
    }
}
