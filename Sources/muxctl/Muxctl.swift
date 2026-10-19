import Foundation
import MuxShotsControl
import MuxShotsCore

/// Command-line client of the running MuxShots app.
@main
enum Muxctl {
    private static let usage = """
        usage: muxctl list [--json]
               muxctl watch
        """
    private static let jsonFlag = "--json"
    private static let titleWidth = 60

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let listArguments = Array(CommandLine.arguments.dropFirst())
        guard let command = listArguments.first else {
            exit(withMessage: usage)
        }
        let request: ControlRequest
        switch command {
        case "list":
            request = .list
        case "watch":
            request = .watch
        default:
            exit(withMessage: usage)
        }
        let isJson = listArguments.contains(jsonFlag)

        do {
            let connection = try await ControlConnection.connect(to: ControlSocket.url)
            defer { connection.cancel() }
            try await connection.send(request)
            while let message = try await connection.receive(ControlMessage.self) {
                try print(message, isJson: isJson)
            }
        } catch {
            exit(withMessage: "muxctl: \(error)")
        }
    }

    private static func print(_ message: ControlMessage, isJson: Bool) throws {
        if isJson {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            Swift.print(String(decoding: try encoder.encode(message), as: UTF8.self))
            return
        }
        switch message {
        case .windows(let listWindows):
            Swift.print(listWindows.map(row(for:)).joined(separator: "\n"))
            Swift.print("\(listWindows.count) windows")
        case .change(.added(let window)):
            Swift.print("+ \(row(for: window))")
        case .change(.updated(let window)):
            Swift.print("~ \(row(for: window))")
        case .change(.removed(let windowId)):
            Swift.print("- \(windowId)")
        case .failure(let failure):
            exit(withMessage: "muxctl: \(failure)")
        }
    }

    /// One table row: id, flags (Fullscreen, Minimized, On screen), application, frame, title.
    private static func row(for window: WindowRecord) -> String {
        let flags = [
            window.isFullscreen ? "F" : "-",
            window.isMinimized ? "M" : "-",
            window.isOnScreen ? "O" : "-",
        ].joined()
        let frame = window.frame
        let frameText = "\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))"
        return [
            String(describing: window.windowId).padding(toLength: 8, withPad: " ", startingAt: 0),
            flags,
            window.application.name.padding(toLength: 20, withPad: " ", startingAt: 0),
            frameText.padding(toLength: 22, withPad: " ", startingAt: 0),
            String(window.title.prefix(titleWidth)),
        ].joined(separator: " ")
    }

    private static func exit(withMessage message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        Foundation.exit(1)
    }
}
