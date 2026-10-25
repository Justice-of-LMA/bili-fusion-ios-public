import XCTest
@testable import Fusion

final class WebAssetTests: XCTestCase {
    private let home = URL(string: "fusion://app/index.html")!
    private func fixture(_ body: (URL, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("assets-" + UUID().uuidString, isDirectory: true)
        let root = directory.appendingPathComponent("Re Signed.app/Web", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("<h1>local home</h1>".utf8).write(to: root.appendingPathComponent("index.html"))
        try body(directory, root)
    }
    private func expect(_ kind: WebAssetError, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual((error as NSError).domain, WebAssetError.errorDomain, file: file, line: line)
            XCTAssertEqual((error as NSError).code, kind.rawValue, file: file, line: line)
        }
    }
    func testEveryBundledAssetCanBeRead() throws {
        let store = WebAssetStore(root: WebAssetStore.bundledRoot)
        for path in WebAssetStore.paths {
            let asset = try store.load(URL(string: "fusion://app" + path)!)
            XCTAssertFalse(asset.data.isEmpty, path)
            XCTAssertFalse(asset.mime.isEmpty)
        }
    }
    func testNormalizedRootFixesOldPrefixMismatch() throws {
        try fixture { _, root in
            // A non-canonical directory alias must not make a valid child look external.
            let alias = try XCTUnwrap(URL(string: root.absoluteString + "./"))
            let oldFile = alias.appendingPathComponent("index.html").standardizedFileURL
            XCTAssertFalse(oldFile.path.hasPrefix(alias.path + "/"), "Fixture must reproduce the old raw-prefix rejection.")
            XCTAssertEqual(try WebAssetStore(root: alias).load(home).data,
                           try WebAssetStore(root: root).load(home).data)
        }
    }
    func testSymlinkAndTrailingSlashRootAliases() throws {
        try fixture { directory, root in
            let alias = directory.appendingPathComponent("Web-alias", isDirectory: true)
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
            let expected = try Data(contentsOf: root.appendingPathComponent("index.html"))
            for candidate in [root, alias, URL(string: alias.absoluteString + "./")!] {
                XCTAssertEqual(try WebAssetStore(root: candidate).load(home).data, expected)
            }
        }
    }
    func testOnlyPackagedPathsAndTrustedGETOriginAreAllowed() throws {
        let store = WebAssetStore(root: WebAssetStore.bundledRoot)
        for path in ["/../index.html", "/%2e%2e/index.html", "/%252e%252e/index.html", "/%69ndex.html",
                     "//index.html", "/vendor/../index.html", "/vendor%2fdesktop-MIT-notice.txt", "/secret.txt", "/"] {
            expect(.path) { _ = try store.load(URL(string: "fusion://app" + path)!) }
        }
        for address in ["https://app/index.html", "fusion://evil/index.html", "fusion://user@app/index.html", "fusion://app:80/index.html"] {
            expect(.origin) { _ = try store.load(URL(string: address)!) }
        }
        expect(.origin) { _ = try store.load(home, method: "POST") }
    }
    func testSymlinkCannotEscapeIntoSiblingDirectory() throws {
        try fixture { directory, root in
            let outside = directory.appendingPathComponent("Re Signed.app/Web-secret", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            let secret = outside.appendingPathComponent("app.js")
            try Data("not an app resource".utf8).write(to: secret)
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("app.js"), withDestinationURL: secret)
            expect(.outsideRoot) { _ = try WebAssetStore(root: root).load(URL(string: "fusion://app/app.js")!) }
        }
    }
    func testMissingAndInvalidSizeHaveDistinctDiagnostics() throws {
        expect(.root) { _ = try WebAssetStore(root: nil).load(home) }
        try fixture { directory, root in
            expect(.root) { _ = try WebAssetStore(root: directory.appendingPathComponent("absent")).load(home) }
            let js = URL(string: "fusion://app/app.js")!
            expect(.missing) { _ = try WebAssetStore(root: root).load(js) }
            try Data().write(to: root.appendingPathComponent("app.js"))
            expect(.size) { _ = try WebAssetStore(root: root).load(js) }
            try Data(repeating: 0, count: 4 * 1024 * 1024).write(to: root.appendingPathComponent("app.js"))
            expect(.size) { _ = try WebAssetStore(root: root).load(js) }
        }
    }
    func testNSErrorDiagnosticIsSpecificAndDoesNotExposePaths() {
        let error = WebAssetError.root as NSError
        XCTAssertEqual(error.domain, "Fusion.WebAssets")
        XCTAssertEqual(error.code, 103)
        XCTAssertEqual(error.localizedDescription, "安装包内缺少 Web 首页目录")
        XCTAssertEqual(WebAssetError.diagnostic(error), error.localizedDescription)
        let wrapped = NSError(domain: "WebKit", code: 1, userInfo: [NSUnderlyingErrorKey: error])
        XCTAssertEqual(WebAssetError.diagnostic(wrapped), error.localizedDescription)
        XCTAssertNil(WebAssetError.diagnostic(NSError(domain: "Other", code: 1, userInfo: [NSLocalizedDescriptionKey: "/private/user/data"])))
    }
}
