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
        testBackgroundInjectionOrdering()
        testUserInputInterruptClearsPendingWithoutBackspace()
        print("PASS: P2-3/P2-1 injection queue self-test")
    }

    private static func testBackgroundInjectionOrdering() {
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
    }

    private static func testUserInputInterruptClearsPendingWithoutBackspace() {
        let injector = RecordingInjector()
        let stateMachine = InjectionStateMachine(injector: injector)

        stateMachine.onPartial("hello")
        guard stateMachine.pendingLen == 5 else {
            fputs("FAIL: pending text was not recorded before interrupt\n", stderr)
            exit(1)
        }

        stateMachine.onUserInputInterrupted()
        guard stateMachine.pendingLen == 0 else {
            fputs("FAIL: pending text was not cleared after user input interrupt\n", stderr)
            exit(1)
        }

        stateMachine.onPartial("hello world")
        guard stateMachine.pendingLen == 11 else {
            fputs("FAIL: pending text was not updated after interrupt\n", stderr)
            exit(1)
        }

        let expected = [
            "type:hello",
            "type:hello world",
        ]
        guard injector.operations == expected else {
            fputs("FAIL: user input interrupt caused unsafe rewrite: \(injector.operations)\n", stderr)
            exit(1)
        }
    }
}
