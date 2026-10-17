@testable import DownloadCore
import XCTest

final class DriveFolderTests: XCTestCase {
    /// Same encoding as live Drive pages (JS string with \x escapes, \/ and raw UTF-8).
    private func page(title: String, rows: String, token: String = "null") -> String {
        """
        <html><head><title>\(title) - Google Drive</title></head><body>
        <script nonce="x">window['_DRIVE_ivd'] = '\\x5b\\x5b\(rows)\\x5d,\(token),null,null,\\x5b\\x5d,0\\x5d';</script>
        </body></html>
        """
    }

    private func row(_ id: String, _ name: String, _ mime: String, size: Int = 0) -> String {
        let escapedMime = mime.replacingOccurrences(of: "/", with: "\\/")
        return "\\x5b\\x22\(id)\\x22,\\x5b\\x22PARENT\\x22\\x5d,\\x22\(name)\\x22,\\x22\(escapedMime)\\x22,0,null,0,0,0,1,1,null,null,\(size)\\x5d"
    }

    func testFolderIDFromLinks() {
        XCTAssertEqual(DriveFolder.folderID(from: URL(string: "https://drive.google.com/drive/folders/1t_Tkdn6iwmMPz?usp=sharing")!), "1t_Tkdn6iwmMPz")
        XCTAssertEqual(DriveFolder.folderID(from: URL(string: "https://drive.google.com/drive/u/0/folders/ABC")!), "ABC")
        XCTAssertNil(DriveFolder.folderID(from: URL(string: "https://drive.google.com/file/d/ABC/view")!))
        XCTAssertNil(DriveFolder.folderID(from: URL(string: "https://example.com/drive/folders/ABC")!))
    }

    func testUnescapeJavaScript() {
        XCTAssertEqual(DriveFolder.unescapeJavaScript(#"\x5b\x22a\x22\x5d"#), #"["a"]"#)
        XCTAssertEqual(DriveFolder.unescapeJavaScript(#"application\/pdf"#), "application/pdf")
        XCTAssertEqual(DriveFolder.unescapeJavaScript(#"café 😀"#), "café 😀")
        XCTAssertEqual(DriveFolder.unescapeJavaScript("Undangan Pernikahan é"), "Undangan Pernikahan é")
    }

    func testParsesLiveStyleListing() throws {
        let rows = [
            row("FILE1", "Undangan.pdf", "application/pdf", size: 6633234),
            row("SUB1", "Foto Prewedding", "application/vnd.google-apps.folder"),
            row("DOC1", "Catatan", "application/vnd.google-apps.document"),
            row("FORM1", "RSVP", "application/vnd.google-apps.form"),
        ].joined(separator: ",")
        let listing = try DriveFolder.parseListing(html: page(title: "Wedding Assets", rows: rows))
        XCTAssertEqual(listing.title, "Wedding Assets")
        XCTAssertFalse(listing.truncated)
        XCTAssertEqual(listing.entries.map(\.id), ["FILE1", "SUB1", "DOC1", "FORM1"])
        XCTAssertEqual(listing.entries[0].size, 6633234)
        XCTAssertTrue(listing.entries[1].isFolder)

        let pdf = DriveFolder.download(for: listing.entries[0])
        XCTAssertEqual(pdf?.url.absoluteString, "https://drive.usercontent.google.com/download?id=FILE1&export=download&confirm=t")
        XCTAssertEqual(pdf?.name, "Undangan.pdf")
        let doc = DriveFolder.download(for: listing.entries[2])
        XCTAssertEqual(doc?.url.absoluteString, "https://docs.google.com/document/d/DOC1/export?format=docx")
        XCTAssertEqual(doc?.name, "Catatan.docx")
        XCTAssertNil(DriveFolder.download(for: listing.entries[3]), "Forms can't be downloaded as files")
    }

    func testTruncatedListingAndPrivateFolder() throws {
        let listing = try DriveFolder.parseListing(html: page(title: "Big", rows: row("A", "a.zip", "application/zip"),
                                                              token: "\\x22nextPageToken\\x22"))
        XCTAssertTrue(listing.truncated)

        XCTAssertThrowsError(try DriveFolder.parseListing(html: "<html><title>Google Drive: Sign-in</title></html>")) {
            XCTAssertEqual($0 as? DownloadEngineError, .folderNotAccessible)
        }
    }

    func testRecursiveListingKeepsFolderStructure() async throws {
        let server = try LocalRangeServer(size: 10)
        server.setPage("/drive/folders/ROOT", page(title: "Proyek", rows: [
            row("F1", "b.pdf", "application/pdf", size: 10),
            row("S1", "Foto", "application/vnd.google-apps.folder"),
            row("F2", "a.zip", "application/zip", size: 20),
        ].joined(separator: ",")))
        server.setPage("/drive/folders/S1", page(title: "Foto", rows: [
            row("F3", "1.jpg", "image/jpeg"),
            row("S2", "Mentah", "application/vnd.google-apps.folder"),
        ].joined(separator: ",")))
        server.setPage("/drive/folders/S2", page(title: "Mentah", rows: row("F4", "2.cr2", "image/x-canon-cr2")))

        let base = server.base
        let contents = try await DriveFolder.contents(of: "ROOT", timeout: 10,
                                                      pageURL: { base.appendingPathComponent("drive/folders/\($0)") })
        XCTAssertEqual(contents.title, "Proyek")
        XCTAssertEqual(contents.files.map { [$0.relativeDirectory, $0.name] },
                       [["", "a.zip"], ["", "b.pdf"], ["Foto", "1.jpg"], ["Foto/Mentah", "2.cr2"]])
        XCTAssertEqual(contents.files.first?.size, 20)
    }
}
