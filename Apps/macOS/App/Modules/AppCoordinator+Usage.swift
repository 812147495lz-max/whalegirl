import AppKit
import WhaleCore
import os
import CryptoKit

@MainActor
extension AppCoordinator {
    func enqueueUsageAnnouncement(_ record: UsageReportRecord) {
        guard !quietMode, UsageReportStore.shared.broadcastsEnabled else { return }
        usageAnnouncements.append(record)
        guard usageAnnouncementTask == nil else { return }
        usageAnnouncementTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.usageAnnouncementTask = nil }
            while !Task.isCancelled, !self.usageAnnouncements.isEmpty {
                if self.quietMode || !UsageReportStore.shared.broadcastsEnabled {
                    self.usageAnnouncements.removeAll(); return
                }
                let next = self.usageAnnouncements.removeFirst()
                let roots = self.agentBoundPets.filter { $0.key.hasPrefix("root|\(next.source)|") }
                let matches = roots.filter { key, _ in
                    guard let id = key.split(separator: "|").last else { return false }
                    let digest = SHA256.hash(data: Data((next.source + ":" + id).utf8))
                        .map { String(format: "%02x", $0) }.joined()
                    return String(digest.prefix(24)) == next.session
                }
                // Only the matching main-task pet and pets the user dragged out may speak.
                // Child-agent pets and the menu-bar peek never announce token usage.
                let bound = Set(self.agentBoundPets.values.map(ObjectIdentifier.init))
                var recipients = self.desktopPets.filter { !bound.contains(ObjectIdentifier($0)) }
                if let root = matches.sorted(by: { $0.key < $1.key }).first?.value {
                    recipients.append(root)
                }
                var announced = false
                for pet in recipients {
                    if pet.sayUsage(next.bubbleText) { announced = true }
                }
                // The report is already saved even when no eligible pet is on screen.
                guard announced else { continue }
                do { try await Task.sleep(for: .seconds(9)) } catch { return }
            }
        }
    }
}
