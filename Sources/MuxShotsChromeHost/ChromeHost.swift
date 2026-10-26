import Foundation
import MuxShotsControl

/// The native messaging host Chrome starts for the MuxShots extension: relays the extension's messages to
/// the running app and the app's back, until either side goes away.
///
/// Chrome frames each message as a 32-bit length in native byte order followed by that many bytes of JSON;
/// the app's control socket carries one JSON message per line.
@main
enum ChromeHost {
    private static let lengthByteCount = MemoryLayout<UInt32>.size
    /// The largest message Chrome lets a host send to an extension.
    private static let maxOutgoingByteCount = 1024 * 1024

    static func main() async {
        let connection: ControlConnection
        do {
            connection = try await ControlConnection.connect(to: ControlSocket.url)
            try await connection.send(ControlRequest.browserSession(browserProcessId: getppid()))
        } catch {
            exit(withMessage: "muxshots-chrome-host: \(error)")
        }
        defer { connection.cancel() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await relayExtensionMessages(to: connection)
            }
            group.addTask {
                await relayAppMessages(from: connection)
            }
            await group.next()
            Foundation.exit(0)
        }
    }

    private static func relayExtensionMessages(to connection: ControlConnection) async {
        var iterator = FileHandle.standardInput.bytes.makeAsyncIterator()
        do {
            while let lengthBytes = try await read(lengthByteCount, from: &iterator) {
                let length = lengthBytes.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
                guard let message = try await read(length, from: &iterator) else {
                    return
                }
                try await connection.sendLine(message)
            }
        } catch {
            FileHandle.standardError.write(Data("muxshots-chrome-host: \(error)\n".utf8))
        }
    }

    private static func relayAppMessages(from connection: ControlConnection) async {
        do {
            while let line = try await connection.receiveLine() {
                guard line.count <= maxOutgoingByteCount else {
                    continue
                }
                var length = UInt32(line.count)
                var frame = Data(bytes: &length, count: lengthByteCount)
                frame.append(line)
                FileHandle.standardOutput.write(frame)
            }
        } catch {
            FileHandle.standardError.write(Data("muxshots-chrome-host: \(error)\n".utf8))
        }
    }

    /// Exactly some bytes from Chrome, or nil once it closes the pipe.
    private static func read(_ count: Int, from iterator: inout FileHandle.AsyncBytes.AsyncIterator) async throws -> Data? {
        var data = Data(capacity: count)
        while data.count < count {
            guard let byte = try await iterator.next() else {
                return nil
            }
            data.append(byte)
        }
        return data
    }

    private static func exit(withMessage message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Foundation.exit(1)
    }
}
