//
//  HUDCalculationTests.swift
//  BetterOSDTests
//
//  Created by yu on 2026/4/11.
//

@testable import BetterOSD
import Testing

struct HUDCalculationTests {
    @Test
    func keepsExpectedStepConstants() {
        #expect(HUDCalculation.standardSteps == 16)
        #expect(HUDCalculation.fineSteps == 64)
    }

    @Test
    func preservesTickActivationBehavior() {
        #expect(HUDCalculation.isTickActive(tickIndex: 8, volume: 0.5))
        #expect(HUDCalculation.isTickActive(tickIndex: 16, volume: 1.0))
        #expect(HUDCalculation.isTickActive(tickIndex: 3, volume: 0.1) == false)
    }

    @Test
    func preservesSegmentFillRatioBehavior() {
        #expect(HUDCalculation.segmentFillRatio(segmentIndex: 0, volume: 0.0) == 0)
        #expect(HUDCalculation.segmentFillRatio(segmentIndex: 0, volume: 0.0625) == 1)
        #expect(HUDCalculation.segmentFillRatio(segmentIndex: 5, volume: 0.375) > 0)
    }
}
