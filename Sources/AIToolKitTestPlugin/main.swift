import Foundation
import AIToolKit

/// A plugin that can be told to misbehave, so the host's failure handling is
/// tested against real process behaviour instead of mocks.
///
/// Doubles as a conformance suite: a third-party author can point these same
/// tests at their own binary.
struct TestTool: AITool {
    let id = "testtool"
    let displayName = "Test Tool"
}

let behaviour = ProcessInfo.processInfo.environment["AITOOLKIT_TEST_BEHAVIOUR"] ?? "ok"

switch behaviour {
case "hang":
    // Accept the request, never answer. The host's timeout must fire.
    // The C `sleep`, not `Task.sleep`: this fixture exists to be a plugin
    // that blocks and declines to cooperate, and a cooperative suspension is
    // precisely what it must not be. `Thread.sleep` is unavailable now that
    // top-level code here is async, and would have been the same idea.
    while readLine() != nil { sleep(3600) }

case "hang-ignoring-sigterm":
    // The peer the old design could not survive. Unblocking a read used to
    // depend on the child dying when asked; a child that declines makes that
    // approach wait forever, so the host has to stop waiting by itself.
    //
    // SIGKILL cannot be trapped, which is why terminate() escalates to it —
    // otherwise this fixture would outlive the test run.
    signal(SIGTERM, SIG_IGN)
    // The C `sleep`, not `Task.sleep`: this fixture exists to be a plugin
    // that blocks and declines to cooperate, and a cooperative suspension is
    // precisely what it must not be. `Thread.sleep` is unavailable now that
    // top-level code here is async, and would have been the same idea.
    while readLine() != nil { sleep(3600) }

case "garbage":
    while readLine() != nil {
        FileHandle.standardOutput.write(Data("this is not json\n".utf8))
    }

case "noisy":
    // A stray debug print on stdout, then a valid reply. The host must skip
    // the first line rather than treat the stream as broken.
    while let line = readLine(strippingNewline: true) {
        FileHandle.standardOutput.write(Data("debug: got a request\n".utf8))
        if let out = await PluginServer.handle(line: Data(line.utf8), tool: TestTool()) {
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

case "partial":
    while readLine() != nil {
        FileHandle.standardOutput.write(Data(#"{"jsonrpc":"2.0","id":1,"resu"#.utf8))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

case "wrong-version":
    while let line = readLine(strippingNewline: true) {
        guard let req = try? JSONDecoder().decode(
            JSONRPCRequest.self, from: Data(line.utf8)) else { continue }
        let res = JSONRPCResponse(id: req.id, result: .object([
            "protocolVersion": .string("99"),
            "capabilities": .object([:]),
        ]), error: nil)
        if let out = try? JSONEncoder().encode(res) {
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

case "crash-after-initialize":
    var seen = false
    while let line = readLine(strippingNewline: true) {
        if seen { exit(1) }
        if let out = await PluginServer.handle(line: Data(line.utf8), tool: TestTool()) {
            FileHandle.standardOutput.write(out)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
        seen = true
    }

default:
    await PluginServer.serve(tool: TestTool())
}
