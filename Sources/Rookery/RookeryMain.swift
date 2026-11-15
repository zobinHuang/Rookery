import AppKit

@main
@MainActor
enum RookeryMain {
    static func main() {
        MuxShotsMigration.run()
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
