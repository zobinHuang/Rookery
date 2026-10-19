import Foundation

/// A thread that runs its own run loop and executes submitted work in submission order.
final class RunLoopThread: Thread, @unchecked Sendable {
    // `runLoop` is written once on the thread before `ready` is signalled and only read after.
    private var runLoop: CFRunLoop?
    private let ready = DispatchSemaphore(value: 0)

    init(name: String) {
        super.init()
        self.name = name
    }

    /// Start the thread and wait until it accepts work.
    func startAndWait() {
        start()
        ready.wait()
    }

    /// Run work on the thread.
    func perform(_ work: @escaping @Sendable () -> Void) {
        guard let runLoop else {
            return
        }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, work)
        CFRunLoopWakeUp(runLoop)
    }

    /// Run work on the thread after a delay.
    func perform(after delay: TimeInterval, _ work: @escaping @Sendable () -> Void) {
        guard let runLoop else {
            return
        }
        let timer = CFRunLoopTimerCreateWithHandler(
            /* allocator */   kCFAllocatorDefault,
            /* fireDate */    CFAbsoluteTimeGetCurrent() + delay,
            /* interval */    0,
            /* flags */       0,
            /* order */       0
        ) { _ in
            work()
        }
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    }

    /// Finish the work already submitted, then exit the thread.
    func shutdown() {
        cancel()
        perform {
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }

    override func main() {
        RunLoop.current.add(NSMachPort(), forMode: .default)
        runLoop = CFRunLoopGetCurrent()
        ready.signal()
        while !isCancelled {
            CFRunLoopRun()
        }
    }
}
