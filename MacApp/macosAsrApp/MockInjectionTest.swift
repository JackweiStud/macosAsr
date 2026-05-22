import Foundation

/// P0c mock partial → final sequence for manual verification in Notes.
enum MockInjectionTest {
    static let steps: [String] = [
        "你好世",
        "你好世界",
        "你好，世界。",
    ]

    static func run(stateMachine: InjectionStateMachine, completion: @escaping (Bool, String) -> Void) {
        AppLogger.log("mock_test_start steps=\(steps.count)")
        stateMachine.onSessionStopped()

        DispatchQueue.global(qos: .userInitiated).async {
            for (index, text) in steps.enumerated() {
                let isFinal = index == steps.count - 1
                Thread.sleep(forTimeInterval: 0.35)
                if isFinal {
                    stateMachine.onFinal(text)
                } else {
                    stateMachine.onPartial(text)
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
            stateMachine.onSessionStopped()
            AppLogger.log("mock_test_done")
            DispatchQueue.main.async {
                completion(true, steps.last ?? "")
            }
        }
    }
}
