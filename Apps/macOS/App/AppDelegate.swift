import AppKit
import Darwin
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "io.whalegirl.app", category: "lifecycle")
    private let instanceGuard = SingleInstanceGuard(name: "io.whalegirl.app")
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // App-hosted tests construct their own views and repositories. Starting
        // the live companion here would contend with the user's running instance.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil ||
            NSClassFromString("XCTestCase") != nil {
            return
        }
        guard instanceGuard.acquire() else {
            logger.notice("A WhaleGirl instance is already running")
            NSApp.terminate(nil)
            return
        }

        do { try DeepSeekChanDialog.prepareFile() }
        catch { logger.error("Could not prepare the editable speech CSV") }

        do {
            let coordinator = try AppCoordinator.make()
            self.coordinator = coordinator
            coordinator.start()
            logger.notice("WhaleGirl Phase 1 started")
        } catch {
            logger.error("Startup failed: \(String(describing: error), privacy: .public)")
            let alert = NSAlert(error: error)
            alert.messageText = "WhaleGirl 无法启动"
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
        instanceGuard.release()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private final class SingleInstanceGuard {
    private let path: String
    private var descriptor: Int32 = -1

    init(name: String) {
        path = NSTemporaryDirectory().appending("\(name).lock")
    }

    func acquire() -> Bool {
        descriptor = open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return false }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            descriptor = -1
            return false
        }
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}
