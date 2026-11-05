//
//  BrightnessKeyControllerTests.swift
//  BetterOSDTests
//
//  Created by yu on 2026/4/11.
//

import AppKit
@testable import BetterOSD
import Testing

@MainActor
struct BrightnessKeyControllerTests {
    @Test
    func doesNotProbeBrightnessInInitializer() {
        let client = FakeDisplayServicesBrightnessClient()

        _ = BrightnessKeyController(displayController: client)

        #expect(client.currentBrightnessCallCount == 0)
        #expect(client.setBrightnessCallCount == 0)
    }

    @Test
    func passesThroughWhenNoBrightnessCanBeRead() {
        let client = FakeDisplayServicesBrightnessClient()
        client.currentBrightnessResult = nil
        let controller = BrightnessKeyController(displayController: client)

        let result = controller.handle(.brightnessUp, fineStep: false)

        #expect(result == .passThrough)
        #expect(controller.currentState == BrightnessState(brightness: 0))
    }

    @Test
    func consumesAndUpdatesStateForBrightnessUp() {
        let client = FakeDisplayServicesBrightnessClient()
        client.currentBrightnessValues = [0.5]
        client.setBrightnessResult = true
        let controller = BrightnessKeyController(displayController: client)

        let result = controller.handle(.brightnessUp, fineStep: false)

        #expect(result == .consumed(didChange: true))
        #expect(controller.currentState == BrightnessState(brightness: 0.5625))
        #expect(client.setBrightnessArguments == [0.5625])
        #expect(client.currentBrightnessCallCount == 1)
    }

    @Test
    func reportsRequestedBrightnessAfterSuccessfulSet() {
        let client = FakeDisplayServicesBrightnessClient()
        client.currentBrightnessValues = [0.5]
        client.setBrightnessResult = true
        let controller = BrightnessKeyController(displayController: client)

        let result = controller.handle(.brightnessUp, fineStep: false)

        #expect(result == .consumed(didChange: true))
        #expect(controller.currentState == BrightnessState(brightness: 0.5625))
        #expect(client.setBrightnessArguments == [0.5625])
    }

    @Test
    func usesFineStepForBrightnessUp() {
        let client = FakeDisplayServicesBrightnessClient()
        client.currentBrightnessValues = [0.5]
        client.setBrightnessResult = true
        let controller = BrightnessKeyController(displayController: client)

        let result = controller.handle(.brightnessUp, fineStep: true)

        #expect(result == .consumed(didChange: true))
        #expect(controller.currentState == BrightnessState(brightness: 0.515625))
        #expect(client.setBrightnessArguments == [0.515625])
    }

    @Test
    func consumesWithoutDidChangeAtLowerBound() {
        let client = FakeDisplayServicesBrightnessClient()
        client.currentBrightnessValues = [0.0]
        let controller = BrightnessKeyController(displayController: client)

        let result = controller.handle(.brightnessDown, fineStep: false)

        #expect(result == .consumed(didChange: false))
        #expect(controller.currentState == BrightnessState(brightness: 0.0))
        #expect(client.setBrightnessCallCount == 0)
    }

    @Test
    func consumesWithoutDidChangeAtUpperBound() {
        let client = FakeDisplayServicesBrightnessClient()
        client.currentBrightnessValues = [1.0]
        let controller = BrightnessKeyController(displayController: client)

        let result = controller.handle(.brightnessUp, fineStep: false)

        #expect(result == .consumed(didChange: false))
        #expect(controller.currentState == BrightnessState(brightness: 1.0))
        #expect(client.setBrightnessCallCount == 0)
    }

    @Test
    func targetedHandleStepsOnlyTheGivenDisplay() {
        let client = FakeDisplayServicesBrightnessClient()
        client.targetedBrightnessValues = [0.5]
        client.setBrightnessResult = true
        let controller = BrightnessKeyController(displayController: client)

        let result = controller.handle(.brightnessUp, fineStep: false, targetDisplayID: 99)

        #expect(result == .consumed(didChange: true))
        #expect(controller.currentState == BrightnessState(brightness: 0.5625))
        #expect(client.targetedSetArguments == [0.5625])
        #expect(client.currentBrightnessCallCount == 0)
        #expect(client.setBrightnessCallCount == 0)
    }

    @Test
    func rapidPressesAdvanceFromTheRequestedLevelWhileTheDisplayIsAnimating() {
        let client = FakeDisplayServicesBrightnessClient()
        client.currentBrightnessValues = [0.5, 0.52, 0.54]
        client.setBrightnessResult = true
        let controller = BrightnessKeyController(displayController: client, uptime: { 10 }, transitionDuration: { 1 })

        #expect(controller.handle(.brightnessUp, fineStep: false) == .consumed(didChange: true))
        #expect(controller.handle(.brightnessUp, fineStep: false) == .consumed(didChange: true))
        #expect(controller.handle(.brightnessDown, fineStep: false) == .consumed(didChange: true))

        #expect(client.setBrightnessArguments == [0.5625, 0.625, 0.5625])
        #expect(controller.currentState == BrightnessState(brightness: 0.5625))
    }

    @Test
    func readsTheDisplayAgainAfterTheTransitionWindow() {
        let client = FakeDisplayServicesBrightnessClient()
        client.currentBrightnessValues = [0.5, 0.75]
        client.setBrightnessResult = true
        var now: TimeInterval = 10
        let controller = BrightnessKeyController(displayController: client, uptime: { now }, transitionDuration: { 1 })

        #expect(controller.handle(.brightnessUp, fineStep: false) == .consumed(didChange: true))
        now = 11
        #expect(controller.handle(.brightnessUp, fineStep: false) == .consumed(didChange: true))

        #expect(client.setBrightnessArguments == [0.5625, 0.8125])
    }

    @Test
    func usesRequestedLevelWithinOneSecondWhileDisplayIsAnimating() {
        let client = FakeDisplayServicesBrightnessClient()
        client.currentBrightnessValues = [0.5, 0.52]
        client.setBrightnessResult = true
        var now: TimeInterval = 10
        let controller = BrightnessKeyController(displayController: client, uptime: { now }, transitionDuration: { 1 })

        #expect(controller.handle(.brightnessUp, fineStep: false) == .consumed(didChange: true))
        now = 10.75
        #expect(controller.handle(.brightnessUp, fineStep: false) == .consumed(didChange: true))

        #expect(client.setBrightnessArguments == [0.5625, 0.625])
    }

    @Test
    func instantDurationUsesLiveBrightnessForEachPress() {
        let client = FakeDisplayServicesBrightnessClient()
        client.currentBrightnessValues = [0.5, 0.75]
        client.setBrightnessResult = true
        let controller = BrightnessKeyController(displayController: client, uptime: { 10 }, transitionDuration: { 0 })

        #expect(controller.handle(.brightnessUp, fineStep: false) == .consumed(didChange: true))
        #expect(controller.handle(.brightnessUp, fineStep: false) == .consumed(didChange: true))

        #expect(client.setBrightnessArguments == [0.5625, 0.8125])
    }

    @Test
    func twoSecondDurationKeepsRequestedLevelBetweenPresses() {
        let client = FakeDisplayServicesBrightnessClient()
        client.currentBrightnessValues = [0.5, 0.52]
        client.setBrightnessResult = true
        var now: TimeInterval = 10
        let controller = BrightnessKeyController(displayController: client, uptime: { now }, transitionDuration: { 2 })

        #expect(controller.handle(.brightnessUp, fineStep: false) == .consumed(didChange: true))
        now = 11.5
        #expect(controller.handle(.brightnessUp, fineStep: false) == .consumed(didChange: true))

        #expect(client.setBrightnessArguments == [0.5625, 0.625])
    }
}

@MainActor
private final class FakeDisplayServicesBrightnessClient: DisplayServicesBrightnessControlling, TargetedBrightnessControlling {
    var currentBrightnessCallCount = 0
    var setBrightnessCallCount = 0
    var currentBrightnessResult: Float?
    var currentBrightnessValues: [Float] = []
    var setBrightnessResult = false
    var setBrightnessArguments: [Float] = []

    // Targeted (⇧+brightness) recording.
    var targetedBrightnessValues: [Float] = []
    var targetedSetArguments: [Float] = []

    func currentBrightness() -> Float? {
        currentBrightnessCallCount += 1

        if currentBrightnessValues.isEmpty == false {
            return currentBrightnessValues.removeFirst()
        }

        return currentBrightnessResult
    }

    func setBrightness(_ brightness: Float) -> Bool {
        setBrightnessCallCount += 1
        setBrightnessArguments.append(brightness)
        return setBrightnessResult
    }

    func currentBrightness(ofDisplay displayID: CGDirectDisplayID) -> Float? {
        if targetedBrightnessValues.isEmpty == false {
            return targetedBrightnessValues.removeFirst()
        }

        return currentBrightnessResult
    }

    func setBrightness(_ brightness: Float, ofDisplay displayID: CGDirectDisplayID) -> Bool {
        targetedSetArguments.append(brightness)
        return setBrightnessResult
    }
}
