//
//  BrightnessKeyController.swift
//  BetterOSD
//
//  Created by yu on 2026/4/11.
//

import CoreGraphics
import Foundation

final class BrightnessKeyController {
    private static let transitionWindow: TimeInterval = 0.5

    private enum Destination: Hashable {
        case allDisplays
        case display(CGDirectDisplayID)
    }

    private struct PendingStep {
        let target: Float
        let issuedAt: TimeInterval
    }

    private let displayController: any DisplayServicesBrightnessControlling & TargetedBrightnessControlling
    private let uptime: () -> TimeInterval
    private var pendingSteps: [Destination: PendingStep] = [:]
    private(set) var currentState = BrightnessState(brightness: 0)

    init(
        displayController: any DisplayServicesBrightnessControlling & TargetedBrightnessControlling = CompositeBrightnessClient(),
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.displayController = displayController
        self.uptime = uptime
    }

    func handle(_ key: MediaKeyMonitor.MediaKey, fineStep: Bool) -> MediaKeyHandlingResult {
        step(key: key, fineStep: fineStep, destination: .allDisplays)
    }

    /// ⇧+brightness: adjust only the given display (the one under the
    /// pointer) instead of the all-displays sweep of a bare press.
    func handle(_ key: MediaKeyMonitor.MediaKey, fineStep: Bool, targetDisplayID: CGDirectDisplayID) -> MediaKeyHandlingResult {
        step(key: key, fineStep: fineStep, destination: .display(targetDisplayID))
    }

    private func step(
        key: MediaKeyMonitor.MediaKey,
        fineStep: Bool,
        destination: Destination
    ) -> MediaKeyHandlingResult {
        guard key == .brightnessUp || key == .brightnessDown else {
            return .passThrough
        }

        let currentBrightness: Float?
        switch destination {
        case .allDisplays:
            currentBrightness = displayController.currentBrightness()
        case .display(let displayID):
            currentBrightness = displayController.currentBrightness(ofDisplay: displayID)
        }
        guard let currentBrightness else {
            pendingSteps.removeValue(forKey: destination)
            return .passThrough
        }

        // DisplayServices animates asynchronously. During a quick sequence of
        // key presses, readback can still be between the old and requested
        // levels. Use the last requested level as the next step's base.
        let now = uptime()
        let baseBrightness: Float
        if let pending = pendingSteps[destination], now - pending.issuedAt < Self.transitionWindow {
            baseBrightness = pending.target
        } else {
            pendingSteps.removeValue(forKey: destination)
            baseBrightness = currentBrightness
        }

        let stepsPerUnit = fineStep ? HUDCalculation.fineSteps : HUDCalculation.standardSteps
        let currentStep = Int(round(baseBrightness * Float(stepsPerUnit)))
        let targetStep = max(0, min(stepsPerUnit, currentStep + (key == .brightnessUp ? 1 : -1)))
        let targetBrightness = Float(targetStep) / Float(stepsPerUnit)

        if targetStep == currentStep {
            currentState = BrightnessState(brightness: targetBrightness)
            return .consumed(didChange: false)
        }

        let didWrite: Bool
        switch destination {
        case .allDisplays:
            didWrite = displayController.setBrightness(targetBrightness)
        case .display(let displayID):
            didWrite = displayController.setBrightness(targetBrightness, ofDisplay: displayID)
        }
        guard didWrite else {
            return .passThrough
        }

        pendingSteps[destination] = PendingStep(target: targetBrightness, issuedAt: now)
        currentState = BrightnessState(brightness: targetBrightness)
        return .consumed(didChange: true)
    }
}
