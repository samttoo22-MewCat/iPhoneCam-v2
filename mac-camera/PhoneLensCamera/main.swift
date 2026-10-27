import AppKit

@main
struct PhoneLensCameraMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = HostApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
