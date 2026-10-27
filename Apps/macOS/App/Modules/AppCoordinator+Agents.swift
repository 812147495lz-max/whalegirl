import AppKit
import WhaleCore
import os

@MainActor
extension AppCoordinator {
    func connectAgentModule() {
        agentCompanions.onSpawn = { [weak self] key in
            guard let self else { return }
            if let existing = self.agentBoundPets[key] {
                existing.cancelAgentDeparture()
                if key.hasPrefix("root|dsh|") { self.startDSHStatus(for: key) }
                return
            }
            guard let screen = NSScreen.main ?? NSScreen.screens.first else {
                self.logger.error("Agent companion could not find a display")
                self.agentCompanions.dismiss(key); return
            }
            let area = screen.visibleFrame
            let isDSHMain = key.hasPrefix("root|dsh|")
            let point: CGPoint
            if isDSHMain {
                let height = DisplayGeometry.fullHeight(screenFrame: screen.frame, userScale: self.displayScale)
                let width = height * self.repository.canvasAspect(for: "full.idle")
                let slot = self.agentBoundPets.keys.filter { $0.hasPrefix("root|dsh|") }.count % 3
                point = CGPoint(x: area.maxX - width / 2 - 16 - CGFloat(slot) * width * 0.75,
                                y: area.minY + height / 2 + 12)
            } else {
                point = CGPoint(x: area.minX + area.width * Double.random(in: 0.25...0.75),
                                y: area.minY + area.height * Double.random(in: 0.25...0.75))
            }
            guard let pet = self.spawnDesktopPet(at: point, agentManaged: true, dshBalanceCompanion: isDSHMain) else { self.agentCompanions.dismiss(key); return }
            self.agentBoundPets[key] = pet
            let id = key.split(separator: "|").last.map(String.init) ?? "agent"
            let introduction = key.hasPrefix("root|")
                ? "\(self.agentCompanions.labels[key] ?? "主 Agent") 开始工作啦"
                : AgentCompanionSpeech.introduction(id: id, label: self.agentCompanions.labels[key])
            pet.beginAgentLife(introduction: introduction)
            if isDSHMain { self.startDSHStatus(for: key) }
            self.logger.notice("Agent companion created; visible=\(pet.isVisible, privacy: .public), count=\(self.agentBoundPets.count, privacy: .public)")
        }
        agentCompanions.onThinking = { [weak self] key, line in
            guard !key.hasPrefix("root|dsh|") else { return }
            self?.agentBoundPets[key]?.sayThinking(line)
        }
        agentCompanions.onFinished = { [weak self] key, connected in
            guard let self, let pet = self.agentBoundPets[key], let deadline = self.agentCompanions.roster.entries[key]?.retireAt else { return }
            let summary = AgentCompanionSpeech.ending(label: key.hasPrefix("root|") ? nil : self.agentCompanions.labels[key], disconnected: !connected)
            pet.prepareAgentDeparture(summary: summary, deadline: deadline)
        }
        agentCompanions.onResumed = { [weak self] key in
            self?.agentBoundPets[key]?.cancelAgentDeparture()
            if key.hasPrefix("root|dsh|") { self?.startDSHStatus(for: key, delay: 0) }
        }
        agentCompanions.onClose = { [weak self] key in
            guard let self, let pet = self.agentBoundPets[key] else { return }
            pet.completeAgentDeparture { [weak self, weak pet] in
                guard let self, let pet, self.agentBoundPets[key] === pet else { return }
                self.closeDesktopPet(pet)
            }
        }
        aiObservation = AIMonitorObservation(NotificationCenter.default.addObserver(forName: AIMonitorStore.changed,
            object: AIMonitorStore.shared, queue: .main) { [weak self] _ in MainActor.assumeIsolated {
                guard let self else { return }
                let enabled = AIMonitorStore.shared.preferences.autoAgentPets
                if !enabled { self.agentBoundPets.values.forEach { $0.cancelAgentDeparture() } }
                self.agentCompanions.setEnabled(enabled)
            } })
    }

    func startDSHStatus(for key: String, delay: TimeInterval = 2) {
        dshStatusBegins[key] = Date().addingTimeInterval(delay)
        AIMonitorStore.shared.setDSHCompanionActive(true)
        guard dshStatusTask == nil else { return }
        dshStatusTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let active = self.agentBoundPets.filter { key, _ in
                    key.hasPrefix("root|dsh|") && self.agentCompanions.roster.entries[key]?.dismissed == false
                        && self.agentCompanions.roster.entries[key]?.retireAt == nil
                }
                guard !active.isEmpty else {
                    AIMonitorStore.shared.setDSHCompanionActive(false)
                    self.dshStatusBegins.removeAll(); self.dshStatusTask = nil; return
                }
                AIMonitorStore.shared.refreshDSHPriceIfNeeded()
                for (key, pet) in active where Date() >= (self.dshStatusBegins[key] ?? .distantPast) {
                    pet.setAgentStatus(AIMonitorStore.shared.dshCompanionText)
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
}
