import AppKit

@main
enum MediaViewApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        // NSApplication.delegate 是弱引用，必须将委托保留至事件循环结束。
        withExtendedLifetime(delegate) { application.run() }
    }
}
