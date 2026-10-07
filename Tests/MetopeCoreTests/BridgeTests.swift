import XCTest
@testable import MetopeCore

@MainActor final class BridgeTests: XCTestCase {
    private func client(script: String) throws -> (BridgeClient, URL) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("MetopeBridgeTest-\(UUID().uuidString).py")
        try script.write(to: file, atomically: true, encoding: .utf8)
        return (BridgeClient(executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: [file.path]), file)
    }
    func testSplitFramesIgnoreStaleRequestAndDeliverProgress() async throws {
        let (client, file) = try client(script: """
        import sys,json,time,uuid
        for line in sys.stdin:
          r=json.loads(line)
          print(json.dumps({'id':str(uuid.uuid4()),'phase':'done','result':{'data':False}}),flush=True)
          print(json.dumps({'id':r['id'],'phase':'progress','result':{'data':{'name':'x'}}}),flush=True)
          result=json.dumps({'id':r['id'],'phase':'done','result':{'data':True}})+'\\n'
          sys.stdout.write(result[:12]);sys.stdout.flush();time.sleep(0.02)
          sys.stdout.write(result[12:]);sys.stdout.flush()
        """)
        defer { client.stop(); try? FileManager.default.removeItem(at: file) }
        var events = 0
        let result = try await client.request("Walk") { _ in events += 1 }
        XCTAssertEqual(result, .bool(true)); XCTAssertEqual(events, 1)
    }
    func testConcurrentRequestRejectedAndCancellationResolvesPending() async throws {
        let (client, file) = try client(script: "import sys,time\nfor line in sys.stdin: time.sleep(60)\n")
        defer { client.stop(); try? FileManager.default.removeItem(at: file) }
        let first = Task { try await client.request("Walk") }
        try await Task.sleep(for: .milliseconds(150))
        do { _ = try await client.request("FetchStorages"); XCTFail("Overlapping request was accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("operation")) }
        client.stop()
        do { _ = try await first.value; XCTFail("Cancellation did not fail request") } catch { XCTAssertEqual((error as? MTPError)?.code, "Cancelled") }
    }
    func testHelperCrashResolvesPending() async throws {
        let (client, file) = try client(script: "import sys\nsys.stdin.readline()\nsys.exit(17)\n")
        defer { client.stop(); try? FileManager.default.removeItem(at: file) }
        do { _ = try await client.request("Initialize"); XCTFail("Crash was reported as success") }
        catch { XCTAssertEqual((error as? MTPError)?.code, "Disconnected") }
    }
    func testFinalEngineErrorPropagates() async throws {
        let (client, file) = try client(script: """
        import sys,json
        for line in sys.stdin:
          r=json.loads(line)
          print(json.dumps({'id':r['id'],'phase':'done','result':{'errorType':'ErrorStorageFull','error':'StoreFull','data':True}}),flush=True)
        """)
        defer { client.stop(); try? FileManager.default.removeItem(at: file) }
        do { _ = try await client.request("UploadFiles"); XCTFail("Error reported as success") }
        catch { XCTAssertEqual((error as? MTPError)?.code, "ErrorStorageFull") }
    }
}
