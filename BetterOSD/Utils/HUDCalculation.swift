//
//  HUDCalculation.swift
//  BetterOSD
//
//  Created by yu on 2025/12/26.
//

import Foundation

nonisolated enum HUDCalculation {
    static let fineSteps = 64
    static let standardSteps = 16
    static let fineStepsPerStandardStep = fineSteps / standardSteps

    static func volumeToFineStep(_ volume: Float) -> Int {
        Int(round(volume * Float(fineSteps)))
    }

    static func isTickActive(tickIndex: Int, volume: Float) -> Bool {
        let volumeStep = volumeToFineStep(volume)
        let tickStep = tickIndex * fineStepsPerStandardStep
        return volumeStep >= tickStep
    }

    static func segmentFillRatio(segmentIndex: Int, volume: Float) -> CGFloat {
        let volumeStep = volumeToFineStep(volume)
        let segmentStartStep = segmentIndex * fineStepsPerStandardStep
        let segmentEndStep = (segmentIndex + 1) * fineStepsPerStandardStep

        if volumeStep >= segmentEndStep {
            return 1.0
        } else if volumeStep > segmentStartStep {
            let stepsInSegment = volumeStep - segmentStartStep
            return CGFloat(stepsInSegment) / CGFloat(fineStepsPerStandardStep)
        } else {
            return 0.0
        }
    }
}
