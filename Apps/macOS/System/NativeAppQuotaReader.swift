import AppKit
@preconcurrency import ApplicationServices
import WhaleCore

/// Uses the macOS public Accessibility API only after the user grants access.
/// No token extraction, private HTTP calls, navigation, prompt controls or chat scanning.
enum NativeAppQuotaReader {
    static let bundleIDs = ["gemini": "com.google.GeminiMacOS", "grok": "com.anysphere.sand"]
    @MainActor static func applicationURL(_ id: String) -> URL? {
        guard let bundleID = bundleIDs[id] else { return nil }
        let name = id == "gemini" ? "Gemini.app" : "Grok Bot.app"
        // A mounted installer may have the same bundle ID. Prefer the installed copy.
        for directory in [URL(fileURLWithPath: "/Applications", isDirectory: true), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
            let url = directory.appendingPathComponent(name)
            if Bundle(url: url)?.bundleIdentifier == bundleID { return url }
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
    @MainActor static func read(_ id: String) async -> AIQuotaReading {
        guard let bundleID = bundleIDs[id] else { return .init(providerId: id, state: "unsupported") }
        guard let url = applicationURL(id) else { return .init(providerId: id, state: "notInstalled") }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }) else { return .init(providerId: id, state: "appNotRunning") }
        guard AXIsProcessTrusted() else { return .init(providerId: id, state: "accessibilityRequired") }
        let pid = app.processIdentifier
        return await Task.detached(priority: .utility) { readUsageWindow(provider: id, pid: pid) }.value
    }
    @MainActor static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    private static func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &result) == .success else { return nil }
        return result
    }
    private static func text(_ element: AXUIElement, _ key: String) -> String { value(element, key) as? String ?? "" }
    private static func readUsageWindow(provider: String, pid: pid_t) -> AIQuotaReading {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let windows = value(app, kAXWindowsAttribute) as? [AXUIElement] else { return .init(providerId: provider, state: "nativeUnavailable") }
        // Only an explicitly named Usage window is eligible. Never traverse the normal chat window.
        let names = ["用量限额", "用量与账单", "用量和账单", "Usage limits", "Usage Limits", "Usage & Billing", "Usage and Billing"]
        guard let window = windows.first(where: { names.contains(text($0, kAXTitleAttribute)) }) else {
            // Grok 0.75 embeds billing in its chat window and currently exposes an empty
            // renderer AX tree even after Electron's documented accessibility request.
            // Asking the user to open the already-open pane would be misleading.
            return .init(providerId: provider, state: provider == "grok" ? "nativeUnavailable" : "usageViewRequired")
        }
        var stack = [window], collected: [String] = [], visited = 0
        let deadline = Date().addingTimeInterval(4)
        while let node = stack.popLast(), visited < 3000, Date() < deadline {
            visited += 1
            AXUIElementSetMessagingTimeout(node, 0.08)
            let role = text(node, kAXRoleAttribute)
            if role == kAXStaticTextRole || role == "AXTextElement" {
                for key in [kAXValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute] {
                    let line = text(node, key)
                    if !line.isEmpty, line.count < 3000, collected.last != line { collected.append(line) }
                }
            }
            // Do not collect editable text, buttons or any other application window. Only parsed quota numbers leave this function.
            if role != kAXTextAreaRole && role != kAXTextFieldRole, let children = value(node, kAXChildrenAttribute) as? [AXUIElement] {
                stack.append(contentsOf: children.reversed())
            }
        }
        guard stack.isEmpty else { return .init(providerId: provider, state: "timeout") }
        return NativeQuotaText.reading(provider: provider, text: collected.joined(separator: "\n"))
    }

}
