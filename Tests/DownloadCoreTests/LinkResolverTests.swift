@testable import DownloadCore
import XCTest

final class LinkResolverTests: XCTestCase {
    private func direct(_ string: String) -> String? {
        LinkResolver.directURL(for: URL(string: string)!)?.absoluteString
    }

    func testGoogleDriveShareLinks() {
        let expected = "https://drive.usercontent.google.com/download?id=1AbC_dEf-123&export=download&confirm=t"
        XCTAssertEqual(direct("https://drive.google.com/file/d/1AbC_dEf-123/view?usp=sharing"), expected)
        XCTAssertEqual(direct("https://drive.google.com/file/d/1AbC_dEf-123/edit"), expected)
        XCTAssertEqual(direct("https://drive.google.com/open?id=1AbC_dEf-123"), expected)
        XCTAssertEqual(direct("https://drive.google.com/uc?id=1AbC_dEf-123&export=download"), expected)
        XCTAssertEqual(direct("https://docs.google.com/uc?export=download&id=1AbC_dEf-123"), expected)
        XCTAssertEqual(direct("https://drive.google.com/file/d/XYZ/view?resourcekey=0-abc"),
                       "https://drive.usercontent.google.com/download?id=XYZ&export=download&confirm=t&resourcekey=0-abc")
        XCTAssertNil(direct("https://drive.google.com/drive/folders/1AbC"), "folders are not single files")
    }

    func testGoogleDocsExportAsOfficeFiles() {
        XCTAssertEqual(direct("https://docs.google.com/document/d/DOC1/edit"),
                       "https://docs.google.com/document/d/DOC1/export?format=docx")
        XCTAssertEqual(direct("https://docs.google.com/spreadsheets/d/SHEET1/edit#gid=0"),
                       "https://docs.google.com/spreadsheets/d/SHEET1/export?format=xlsx")
        XCTAssertEqual(direct("https://docs.google.com/presentation/d/DECK1/view"),
                       "https://docs.google.com/presentation/d/DECK1/export?format=pptx")
    }

    func testDropboxGitHubSharePointPixeldrain() {
        XCTAssertEqual(direct("https://www.dropbox.com/s/abc123/report.pdf?dl=0"),
                       "https://www.dropbox.com/s/abc123/report.pdf?dl=1")
        XCTAssertEqual(direct("https://www.dropbox.com/scl/fi/xyz/video.mp4?rlkey=k&dl=0"),
                       "https://www.dropbox.com/scl/fi/xyz/video.mp4?rlkey=k&dl=1")
        XCTAssertEqual(direct("https://github.com/apple/swift/blob/main/README.md"),
                       "https://raw.githubusercontent.com/apple/swift/main/README.md")
        XCTAssertEqual(direct("https://contoso.sharepoint.com/:u:/g/personal/a/EaBc?e=1"),
                       "https://contoso.sharepoint.com/:u:/g/personal/a/EaBc?e=1&download=1")
        XCTAssertEqual(direct("https://pixeldrain.com/u/AbCd12"), "https://pixeldrain.com/api/file/AbCd12?download")
    }

    func testOrdinaryLinksAreLeftAlone() {
        XCTAssertNil(direct("https://example.com/files/setup.dmg"))
        XCTAssertNil(direct("https://github.com/apple/swift/releases/download/v1/x.zip"))
        XCTAssertNil(direct("https://www.dropbox.com/home"))
    }

    func testDriveVirusScanInterstitial() {
        let html = """
        <html><body><div>Google Drive can't scan this file for viruses.</div>
        <form id="download-form" action="https://drive.usercontent.google.com/download" method="get">
          <input type="submit" id="uc-download-link" class="goog-inline-block" value="Download anyway"/>
          <input type="hidden" name="id" value="1AbC">
          <input type="hidden" name="export" value="download">
          <input type="hidden" name="confirm" value="t">
          <input type="hidden" name="uuid" value="5f0c-11aa">
        </form></body></html>
        """
        let target = LinkResolver.interstitialTarget(html: html, pageURL: URL(string: "https://drive.usercontent.google.com/download?id=1AbC")!)
        XCTAssertEqual(target?.absoluteString,
                       "https://drive.usercontent.google.com/download?id=1AbC&export=download&confirm=t&uuid=5f0c-11aa")
    }

    func testMediaFireAndMetaRefresh() {
        let mediafire = #"<a class="input popsok" aria-label="Download file" href="https://download2391.mediafire.com/abc/x/file.zip" id="downloadButton">"#
        XCTAssertEqual(LinkResolver.interstitialTarget(html: mediafire, pageURL: URL(string: "https://www.mediafire.com/file/x")!)?.absoluteString,
                       "https://download2391.mediafire.com/abc/x/file.zip")

        let refresh = #"<meta http-equiv="refresh" content="0; url=/files/real.iso">"#
        XCTAssertEqual(LinkResolver.interstitialTarget(html: refresh, pageURL: URL(string: "https://mirror.example.org/get/42")!)?.absoluteString,
                       "https://mirror.example.org/files/real.iso")

        XCTAssertNil(LinkResolver.interstitialTarget(html: "<html><body>Sign in</body></html>",
                                                     pageURL: URL(string: "https://accounts.example.com")!))
    }
}

/// Resolver pipeline against the local server.
final class DownloadResolverTests: XCTestCase {
    func testFollowsInterstitialPageToTheFile() async throws {
        let server = try LocalRangeServer(size: 2 << 20)
        server.setPage("/download", """
        <form id="download-form" action="/files/sample.bin" method="get">
          <input type="hidden" name="id" value="abc"><input type="hidden" name="confirm" value="t">
        </form>
        """)
        let resolved = try await DownloadResolver.resolve(
            RemoteRequest(url: server.base.appendingPathComponent("download")), timeout: 10, maxAttempts: 1)
        XCTAssertEqual(resolved.request.url.path, "/files/sample.bin")
        XCTAssertTrue(resolved.resource.acceptsRanges)
        XCTAssertEqual(resolved.resource.totalBytes, Int64(2 << 20))
        XCTAssertEqual(resolved.resource.contentType, "application/octet-stream")
    }

    func testRefusesToSaveALoginPageAsTheFile() async throws {
        let server = try LocalRangeServer(size: 1000)
        server.setPage("/private", "<html><body><form action=\"/login\">Sign in</form></body></html>")
        do {
            _ = try await DownloadResolver.resolve(
                RemoteRequest(url: server.base.appendingPathComponent("private")), timeout: 10, maxAttempts: 1)
            XCTFail("a login page must not be treated as the file")
        } catch let error as DownloadEngineError {
            XCTAssertEqual(error, .notAFile)
        }
    }

    func testServerThatRejectsRangeHeadersStillDownloads() async throws {
        var options = LocalRangeServer.Options()
        options.rejectRanges = true
        let server = try LocalRangeServer(size: 3 << 20, options: options)
        let resolved = try await DownloadResolver.resolve(RemoteRequest(url: server.url), timeout: 10, maxAttempts: 1)
        XCTAssertFalse(resolved.resource.acceptsRanges)
        XCTAssertEqual(resolved.resource.totalBytes, Int64(3 << 20))

        let file = FileManager.default.temporaryDirectory.appendingPathComponent("norange-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: file) }
        let downloader = RangeDownloader(request: resolved.request, resource: resolved.resource, fileURL: file)
        try await downloader.run()
        XCTAssertEqual(try Data(contentsOf: file), server.content)
    }
}
