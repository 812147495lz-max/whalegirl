import AppKit
import Darwin

@main
@MainActor
enum WhaleGirlMain {
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--apply-whale-update" {
            exit(SoftwareUpdateHelper.run(planURL: URL(fileURLWithPath: CommandLine.arguments[2])))
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
