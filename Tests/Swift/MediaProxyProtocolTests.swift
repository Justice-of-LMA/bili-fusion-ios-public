import XCTest
import Foundation
@testable import Fusion

/// Synthetic HTTPS CDN responses injected at the proxy boundary; only the test client uses loopback.
/// No live room, account, Cookie, signature URL, alternate source or automatic retry is involved.
final class MediaProxyProtocolTests: XCTestCase {
    @MainActor private func response(_ request:URLRequest,code:Int=200,headers:[String:String]=[:])->HTTPURLResponse {
        HTTPURLResponse(url:request.url!,statusCode:code,httpVersion:"HTTP/1.1",headerFields:headers)!
    }
    @MainActor private func load(_ url:URL,method:String="GET",range:String?=nil) async throws -> (Data,HTTPURLResponse) {
        let configuration=URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage=nil;configuration.httpShouldSetCookies=false;configuration.urlCache=nil
        configuration.timeoutIntervalForRequest=3;configuration.timeoutIntervalForResource=5
        let session=URLSession(configuration:configuration);defer{session.invalidateAndCancel()}
        var request=URLRequest(url:url,cachePolicy:.reloadIgnoringLocalCacheData);request.httpMethod=method
        if let range{request.setValue(range,forHTTPHeaderField:"Range")}
        let (data,response)=try await session.data(for:request)
        return (data,try XCTUnwrap(response as? HTTPURLResponse))
    }
    @MainActor func testHeadUsesUpstreamHeadWithoutDownloadingItsAdvertisedBody() async throws {
        var calls=0
        let proxy=MediaProxy(fetch:{request,limit in
            calls += 1;XCTAssertEqual(request.httpMethod,"HEAD");XCTAssertGreaterThan(limit,24*1024*1024)
            XCTAssertNil(request.value(forHTTPHeaderField:"Cookie"))
            return (Data(),self.response(request,headers:["Content-Type":"video/mp4","Content-Length":"55000000","Accept-Ranges":"bytes"]))
        })
        try await proxy.start();defer{proxy.stop()}
        let local=try proxy.register(URL(string:"https://test.bilivideo.com/live/init.mp4")!)
        let (data,response)=try await load(local,method:"HEAD")
        XCTAssertEqual(calls,1);XCTAssertTrue(data.isEmpty);XCTAssertEqual(response.statusCode,200)
        XCTAssertEqual(response.value(forHTTPHeaderField:"Content-Length"),"55000000")
        XCTAssertEqual(response.value(forHTTPHeaderField:"Accept-Ranges"),"bytes")
    }
    @MainActor func testManifestRangeProbeFetchesWholePlaylistAndEveryReloadIsFresh() async throws {
        var calls=0
        let proxy=MediaProxy(fetch:{request,_ in
            calls += 1;XCTAssertEqual(request.httpMethod,"GET");XCTAssertNil(request.value(forHTTPHeaderField:"Range"))
            XCTAssertEqual(request.cachePolicy,.reloadIgnoringLocalCacheData);XCTAssertEqual(request.value(forHTTPHeaderField:"Cache-Control"),"no-cache")
            let body="#EXTM3U\n#EXT-X-TARGETDURATION:3\n#EXT-X-MEDIA-SEQUENCE:\(calls)\n#EXTINF:3,\nsegment-\(calls).ts\n"
            return (Data(body.utf8),self.response(request,headers:["Content-Type":"application/vnd.apple.mpegurl"]))
        })
        try await proxy.start();defer{proxy.stop()}
        let local=try proxy.register(URL(string:"https://test.bilivideo.com/live/index.m3u8")!)
        for sequence in 1...2 {
            let (data,response)=try await load(local,range:"bytes=0-1")
            let text=try XCTUnwrap(String(data:data,encoding:.utf8))
            XCTAssertEqual(response.statusCode,200);XCTAssertTrue(text.hasPrefix("#EXTM3U"));XCTAssertTrue(text.contains("#EXT-X-MEDIA-SEQUENCE:\(sequence)"))
            XCTAssertTrue(text.contains("http://127.0.0.1:"));XCTAssertFalse(text.contains("test.bilivideo.com"))
            XCTAssertNil(response.value(forHTTPHeaderField:"Content-Range"));XCTAssertEqual(response.expectedContentLength,Int64(data.count))
        }
        XCTAssertEqual(calls,2,"A live playlist reload must not be served from a permanent proxy cache")
    }
    @MainActor func testManifestHeadDoesNotAdvertiseUnrewrittenLengthOrAFalseZero() async throws {
        let proxy=MediaProxy(fetch:{request,_ in
            XCTAssertEqual(request.httpMethod,"HEAD");XCTAssertNil(request.value(forHTTPHeaderField:"Range"))
            return (Data(),self.response(request,headers:["Content-Type":"application/vnd.apple.mpegurl","Content-Length":"123"]))
        })
        try await proxy.start();defer{proxy.stop()}
        let (data,response)=try await load(proxy.register(URL(string:"https://test.bilivideo.com/index.m3u8")!),method:"HEAD",range:"bytes=0-1")
        XCTAssertTrue(data.isEmpty);XCTAssertEqual(response.statusCode,200)
        XCTAssertNil(response.value(forHTTPHeaderField:"Content-Length"));XCTAssertEqual(response.mimeType,"application/vnd.apple.mpegurl")
    }
    @MainActor func testSegment206PreservesContentRangeAndExactBody() async throws {
        let proxy=MediaProxy(fetch:{request,_ in
            XCTAssertEqual(request.value(forHTTPHeaderField:"Range"),"bytes=1-2")
            return (Data([0x62,0x63]),self.response(request,code:206,headers:["Content-Type":"video/mp2t","Content-Range":"bytes 1-2/4","Accept-Ranges":"bytes"]))
        })
        try await proxy.start();defer{proxy.stop()}
        let (data,response)=try await load(proxy.register(URL(string:"https://test.bilivideo.com/part.ts")!),range:"bytes=1-2")
        XCTAssertEqual(data,Data([0x62,0x63]));XCTAssertEqual(response.statusCode,206)
        XCTAssertEqual(response.value(forHTTPHeaderField:"Content-Range"),"bytes 1-2/4")
        XCTAssertEqual(response.value(forHTTPHeaderField:"Accept-Ranges"),"bytes");XCTAssertEqual(response.expectedContentLength,2)
    }
    @MainActor func testPartialUnknownManifestIsRejectedWithoutRetryingOrRewritingIt() async throws {
        var calls=0
        let proxy=MediaProxy(fetch:{request,_ in calls += 1;return (Data("#E".utf8),self.response(request,code:206,headers:["Content-Type":"application/vnd.apple.mpegurl","Content-Range":"bytes 0-1/100"]))})
        try await proxy.start();defer{proxy.stop()}
        let (_,response)=try await load(proxy.register(URL(string:"https://test.bilivideo.com/playlist")!),range:"bytes=0-1")
        XCTAssertEqual(response.statusCode,502);XCTAssertEqual(calls,1,"Protocol failure must not trigger another source or automatic retry")
    }
    @MainActor func testActiveFetchOutlivesHeaderDeadlineWithoutClosingTheConnection() async throws {
        var calls=0
        let proxy=MediaProxy(fetch:{request,_ in
            calls += 1;try await Task.sleep(nanoseconds:200_000_000)
            return (Data([0x61,0x62]),self.response(request,headers:["Content-Type":"video/mp2t"]))
        })
        proxy.headerTimeout=0.03;try await proxy.start();defer{proxy.stop()}
        let (data,response)=try await load(proxy.register(URL(string:"https://test.bilivideo.com/slow.ts")!))
        XCTAssertEqual(response.statusCode,200);XCTAssertEqual(data,Data([0x61,0x62]));XCTAssertEqual(calls,1)
    }
    @MainActor func testByteRangeValidationAndFlvPartialHeaderAreStandardsConsistent() throws {
        for value in ["bytes=0-","bytes=0-1","bytes=-32"]{XCTAssertTrue(MediaProxy.validRange(value))}
        for value in ["bytes=-","bytes=-0","bytes=4-2","bytes=0-1,3-4","bytes=999999999999999999999-","bytes=0-1\r\nX-Foo: a"]{XCTAssertFalse(MediaProxy.validRange(value))}
        let request=URLRequest(url:URL(string:"https://test.bilivideo.com/live.flv")!)
        let partial=response(request,code:206,headers:["Content-Range":"bytes 0-1/100","Accept-Ranges":"bytes"])
        let header=try XCTUnwrap(String(data:try XCTUnwrap(MediaBytePipe.responseHeader(partial)),encoding:.utf8))
        XCTAssertTrue(header.hasPrefix("HTTP/1.1 206 Partial Content\r\n"));XCTAssertTrue(header.contains("Content-Range: bytes 0-1/100\r\n"))
        XCTAssertTrue(header.contains("Accept-Ranges: bytes\r\n"));XCTAssertTrue(header.contains("Transfer-Encoding: chunked\r\n"));XCTAssertFalse(header.contains("Content-Length:"))
        XCTAssertNil(MediaBytePipe.responseHeader(response(request,code:206)))
        XCTAssertNil(MediaBytePipe.responseHeader(response(request,code:403)))
    }
}
