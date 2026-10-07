import XCTest
@testable import MetopeCore

final class CoreTests: XCTestCase {
    func testEnginePayloadsPreserveLargeSizes() throws {
        let wire = Data(#"{"errorType":"","error":"","data":[{"size":8589934593,"isFolder":false,"dateAdded":"2026-10-05T16:42:01.000Z","name":"Film.mp4","path":"/Movies/Film.mp4","parentPath":"/Movies","extension":"mp4","parentId":7,"objectId":4294967294}]}"#.utf8)
        let files = try JSONDecoder().decode(EngineEnvelope.self, from: wire).checked().decode([RemoteFile].self)
        XCTAssertEqual(files[0].size, 8_589_934_593)
        XCTAssertEqual(files[0].objectId, 4_294_967_294)
        XCTAssertNotNil(files[0].modified)
    }
    func testStorageCapacityWireFormat() throws {
        let storage = try JSONDecoder().decode(DeviceStorage.self, from: Data(#"{"Sid":65537,"Info":{"StorageDescription":"Internal storage","MaxCapability":128000000000,"FreeSpaceInBytes":64000000000,"AccessCapability":0}}"#.utf8))
        XCTAssertEqual(storage.usedFraction, 0.5)
        XCTAssertTrue(storage.writable)
    }
    func testErrorOnDoneIsNotSuccess() throws {
        let envelope = EngineEnvelope(errorType: "ErrorStorageFull", error: "StoreFull", data: .bool(true))
        XCTAssertThrowsError(try envelope.checked()) { XCTAssertEqual(($0 as? MTPError)?.code, "ErrorStorageFull") }
        XCTAssertEqual(try EngineEnvelope(data: .null).checked(), .null)
    }
    func testRejectTraversalAndAmbiguousNames() throws {
        for name in ["", ".", "..", "a/b", "a:b", "\0bad"] { XCTAssertThrowsError(try TransferSafety.validateName(name), name) }
        for path in ["relative", "/a/../b", "/a//b", "/a/"] { XCTAssertThrowsError(try TransferSafety.validateRemotePath(path), path) }
        XCTAssertEqual(try TransferSafety.child("Šeima.jpg", of: "/Pictures"), "/Pictures/Šeima.jpg")
        XCTAssertThrowsError(try TransferSafety.requireUnique(["photo.JPG", "Photo.jpg"]))
        XCTAssertThrowsError(try TransferSafety.requireUnique(["é.txt", "e\u{301}.txt"]))
    }
    func testManifestRejectsOutsideAndCaseCollision() throws {
        let root = RemoteFile(name: "Photos", path: "/Photos", isFolder: true)
        XCTAssertThrowsError(try TransferSafety.remoteManifest(roots: [root], descendants: [.init(name: "x", path: "/Other/x")]))
        XCTAssertThrowsError(try TransferSafety.remoteManifest(roots: [root], descendants: [.init(name: "a", path: "/Photos/a"), .init(name: "A", path: "/Photos/A")]))
        let manifest = try TransferSafety.remoteManifest(roots: [root], descendants: [.init(name: "a", path: "/Photos/a", size: 17)])
        XCTAssertEqual(try TransferSafety.totalBytes(manifest), 17)
    }
    func testSymlinkIsRejectedBeforeUpload() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"); try Data([1, 2]).write(to: original)
        let link = root.appendingPathComponent("link"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try TransferSafety.localManifest([link]))
    }
    func testTruncatedDownloadNeverPublishes() throws {
        let destination = try temp(); defer { try? FileManager.default.removeItem(at: destination) }
        let staging = try DownloadStaging(destination: destination, manifest: [.init(relativePath: "movie.mp4", size: 8, isFolder: false)])
        try Data([1, 2]).write(to: staging.directory.appendingPathComponent("movie.mp4"))
        XCTAssertThrowsError(try staging.publish())
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("movie.mp4").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staging.directory.path))
    }
    func testPublishRefusesExistingFileAndRetainsOriginal() throws {
        let destination = try temp(); defer { try? FileManager.default.removeItem(at: destination) }
        let original = destination.appendingPathComponent("file.txt"); try Data("original".utf8).write(to: original)
        let staging = try DownloadStaging(destination: destination, manifest: [.init(relativePath: "file.txt", size: 3, isFolder: false)])
        try Data("new".utf8).write(to: staging.directory.appendingPathComponent("file.txt"))
        XCTAssertThrowsError(try staging.publish())
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original")
    }
    func testVerifiedDownloadPublishesEmptyFolderAndZeroByteFile() throws {
        let destination = try temp(); defer { try? FileManager.default.removeItem(at: destination) }
        let staging = try DownloadStaging(destination: destination, manifest: [.init(relativePath: "Folder", size: 0, isFolder: true), .init(relativePath: "Folder/empty", size: 0, isFolder: false)])
        try FileManager.default.createDirectory(at: staging.directory.appendingPathComponent("Folder"), withIntermediateDirectories: false)
        try Data().write(to: staging.directory.appendingPathComponent("Folder/empty"))
        let urls = try staging.publish()
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Folder"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Folder/empty").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.directory.path))
    }
    func testStagingRejectsTraversal() throws {
        let destination = try temp(); defer { try? FileManager.default.removeItem(at: destination) }
        XCTAssertThrowsError(try DownloadStaging(destination: destination, manifest: [.init(relativePath: "../outside", size: 0, isFolder: false)]))
    }
    private func temp() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MetopeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false); return url
    }
}
