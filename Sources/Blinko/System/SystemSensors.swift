import CoreGraphics
import Foundation
import IOKit.ps
import BlinkoCore

/// Keyboard/mouse idleness via CoreGraphics (SC-09).
final class SystemIdleMonitor: IdleMonitor {
    var secondsSinceLastInput: TimeInterval? {
        // `~0` is kCGAnyInputEventType: the last event of any type in the
        // combined session state.
        let anyInput = CGEventType(rawValue: ~0)!
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInput
        )
        return seconds.isFinite ? seconds : nil
    }
}

/// Battery charge and AC state via IOKit power sources (SC-08).
final class SystemBatteryMonitor: BatteryMonitor {
    var level: Double? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let raw = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
            else { continue }
            let info = raw as NSDictionary
            guard let current = info[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = info[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0
            else { continue }
            return min(1, max(0, Double(current) / Double(maximum)))
        }
        return nil
    }

    var isPluggedIn: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        else { return true }
        return type == kIOPSACPowerValue
    }
}
