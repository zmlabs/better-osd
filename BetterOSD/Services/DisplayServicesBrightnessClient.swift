//
//  DisplayServicesBrightnessClient.swift
//  BetterOSD
//
//  Created by yu on 2026/4/11.
//

import ApplicationServices
import Darwin
import Foundation

protocol DisplayServicesBrightnessControlling: AnyObject {
    func currentBrightness() -> Float?
    func setBrightness(_ brightness: Float) -> Bool
}

/// Per-display brightness control — the ⇧+brightness path that adjusts only
/// the display under the pointer instead of the all-displays sweep.
protocol TargetedBrightnessControlling: AnyObject {
    func currentBrightness(ofDisplay displayID: CGDirectDisplayID) -> Float?
    func setBrightness(_ brightness: Float, ofDisplay displayID: CGDirectDisplayID) -> Bool
}

final class DisplayServicesBrightnessClient: DisplayServicesBrightnessControlling, TargetedBrightnessControlling {
    private typealias CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let frameworkPath = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"
    private nonisolated(unsafe) var handle: UnsafeMutableRawPointer?
    private var canChangeBrightness: CanChangeBrightness?
    private var getBrightnessFn: GetBrightness?
    private var setBrightnessFn: SetBrightness?
    private var setBrightnessSmoothFn: SetBrightness?

    func currentBrightness() -> Float? {
        guard let displayID = firstControllableDisplayID(),
              let getBrightnessFn
        else {
            return nil
        }

        var value: Float = 0
        guard getBrightnessFn(displayID, &value) == 0 else { return nil }
        return max(0, min(1, value))
    }

    func setBrightness(_ brightness: Float) -> Bool {
        guard let displayID = firstControllableDisplayID() else { return false }
        return setBrightness(brightness, ofDisplay: displayID)
    }

    /// True when DisplayServices can drive at least one display — i.e. the
    /// built-in panel is active (lid open) or macOS natively supports an
    /// external one. When false, callers should fall back to DDC.
    func hasControllableDisplay() -> Bool {
        firstControllableDisplayID() != nil
    }

    func canControl(displayID: CGDirectDisplayID) -> Bool {
        guard resolveSymbolsIfNeeded(),
              let canChangeBrightness
        else {
            return false
        }
        return canChangeBrightness(displayID)
    }

    func currentBrightness(ofDisplay displayID: CGDirectDisplayID) -> Float? {
        guard canControl(displayID: displayID),
              let getBrightnessFn
        else {
            return nil
        }

        var value: Float = 0
        guard getBrightnessFn(displayID, &value) == 0 else { return nil }
        return max(0, min(1, value))
    }

    func setBrightness(_ brightness: Float, ofDisplay displayID: CGDirectDisplayID) -> Bool {
        guard canControl(displayID: displayID),
              let setBrightnessFn
        else {
            return false
        }

        let target = max(0, min(1, brightness))
        // The smooth private API takes a delta from the current brightness,
        // whereas SetBrightness takes an absolute value. Fall back to the
        // existing setter when the symbol or the current reading is unavailable.
        if let setBrightnessSmoothFn,
           let current = currentBrightness(ofDisplay: displayID),
           abs(target - current) > 0.0001,
           setBrightnessSmoothFn(displayID, target - current) == 0 {
            return true
        }
        return setBrightnessFn(displayID, target) == 0
    }

    private func firstControllableDisplayID() -> CGDirectDisplayID? {
        guard resolveSymbolsIfNeeded(),
              let canChangeBrightness
        else {
            return nil
        }

        var activeCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &activeCount)
        var displays = Array(repeating: CGDirectDisplayID(), count: Int(activeCount))
        let status = CGGetActiveDisplayList(activeCount, &displays, &activeCount)

        guard status == .success else { return nil }
        return displays.first(where: { canChangeBrightness($0) })
    }

    private func resolveSymbolsIfNeeded() -> Bool {
        if getBrightnessFn != nil, setBrightnessFn != nil, canChangeBrightness != nil {
            return true
        }

        guard handle == nil else { return false }
        handle = dlopen(frameworkPath, RTLD_NOW)

        guard let handle else { return false }

        canChangeBrightness = load(handle: handle, symbol: "DisplayServicesCanChangeBrightness")
        getBrightnessFn = load(handle: handle, symbol: "DisplayServicesGetBrightness")
        setBrightnessFn = load(handle: handle, symbol: "DisplayServicesSetBrightness")
        setBrightnessSmoothFn = load(handle: handle, symbol: "DisplayServicesSetBrightnessSmooth")

        return canChangeBrightness != nil && getBrightnessFn != nil && setBrightnessFn != nil
    }

    private func load<T>(handle: UnsafeMutableRawPointer, symbol: String) -> T? {
        guard let pointer = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    deinit {
        if let handle {
            dlclose(handle)
        }
    }
}
