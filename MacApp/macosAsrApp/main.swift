import Cocoa

// NSApplication.delegate 是 weak；swiftc 直编时 @main AppDelegate 可能在 finishLaunching 前被释放。
private let gAppDelegate = AppDelegate()

autoreleasepool {
    let app = NSApplication.shared
    app.delegate = gAppDelegate
    app.setActivationPolicy(.accessory)
    app.run()
}
