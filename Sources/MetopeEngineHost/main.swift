import Foundation
import MetopeCore
import MetopeEngine
import Darwin

signal(SIGPIPE, SIG_IGN)
let engine = MetopeEngine()
let output = FileHandle.standardOutput
func emit(_ id: UUID, _ phase: String, _ result: EngineEnvelope) {
    do {
        var bytes = try JSONEncoder().encode(BridgeEvent(id: id, phase: phase, result: result)); bytes.append(10)
        try output.write(contentsOf: bytes)
    } catch { exit(74) }
}
while let line = readLine() {
    var id = UUID()
    do {
        guard line.utf8.count < 8 * 1024 * 1024 else { throw MTPError(detail: "The engine request is too large.") }
        let request = try JSONDecoder().decode(BridgeRequest.self, from: Data(line.utf8)); id = request.id
        let result = try engine.perform(request) { phase, data in emit(id, phase, EngineEnvelope(data: data)) }
        emit(id, "done", EngineEnvelope(data: result))
    } catch {
        let error = error as? MTPError ?? MTPError(detail: error.localizedDescription)
        emit(id, "done", EngineEnvelope(errorType: error.code, error: error.detail))
    }
}
engine.close()
