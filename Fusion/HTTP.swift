import Foundation

/// The only remote HTTP client: no shared cookies, no automatic redirects, bounded response bodies.
final class HTTP: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    static let shared = HTTP()
    private struct Pending {
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        let limit: Int
        var data = Data()
        var response: HTTPURLResponse?
    }
    private let lock = NSLock()
    private var pending = [Int: Pending]()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.httpShouldSetCookies = false; c.urlCache = nil
        c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 30; c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()
    func fetch(_ request: URLRequest, limit: Int = 2 * 1024 * 1024) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            // URLSession is lazy: concurrent first requests must not create separate
            // sessions whose task identifiers collide in the shared pending map.
            lock.lock()
            let task = session.dataTask(with: request)
            pending[task.taskIdentifier] = Pending(continuation: continuation, limit: limit); lock.unlock()
            task.resume()
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard var p = pending[dataTask.taskIdentifier], let response = response as? HTTPURLResponse, response.expectedContentLength <= p.limit else { completionHandler(.cancel); return }
        p.response = response; pending[dataTask.taskIdentifier] = p; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard var p = pending[dataTask.taskIdentifier] else { return }
        guard p.data.count + data.count <= p.limit else { dataTask.cancel(); return }
        p.data.append(data); pending[dataTask.taskIdentifier] = p
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let p = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let p else { return }
        if let error { p.continuation.resume(throwing: error) }
        else if let response = p.response { p.continuation.resume(returning: (p.data, response)) }
        else { p.continuation.resume(throwing: FusionError("网络响应无效")) }
    }
}
