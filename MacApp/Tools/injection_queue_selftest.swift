import Foundation

final class RecordingInjector: TextInjecting {
    var operations: [String] = []
    var sawMainThreadInjection = false

    func backspace(count: Int) {
        if Thread.isMainThread { sawMainThreadInjection = true }
        operations.append("backspace:\(count)")
    }

    func typeText(_ text: String) {
        if Thread.isMainThread { sawMainThreadInjection = true }
        operations.append("type:\(text)")
    }
}

@main
struct InjectionQueueSelfTest {
    static func main() {
        let injector = RecordingInjector()
        let stateMachine = InjectionStateMachine(injector: injector)

        stateMachine.onPartial("hello")
        stateMachine.onPartial("hello world")
        stateMachine.onFinal("hello there")

        // pendingLen synchronizes with the injection queue, so all enqueued work above is complete.
        guard stateMachine.pendingLen == 0 else {
            fputs("FAIL: pending text was not cleared after final\n", stderr)
            exit(1)
        }

        let expected = [
            "type:hello",
            "type: world",
            "backspace:5",
            "type:there",
        ]
        guard injector.operations == expected else {
            fputs("FAIL: unexpected injection operations: \(injector.operations)\n", stderr)
            exit(1)
        }

        guard !injector.sawMainThreadInjection else {
            fputs("FAIL: injection ran on main thread\n", stderr)
            exit(1)
        }

        print("PASS: P2-3 injection queue self-test")
    }
}
