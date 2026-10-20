#if canImport(SwiftUI)
import Combine
import Foundation
import GameController
import IOKit.ps

/// Game controllers drive the menu like the keyboard (d-pad / left stick: move, A: play, menu or Y: options), and the
/// Mac's battery is shown in the top bar when it has one.
@MainActor
final class ControllerInput: ObservableObject {
    struct Battery: Equatable {
        var percent: Int
        var charging: Bool
        var symbol: String {
            if charging { return "battery.100percent.bolt" }
            switch percent {
            case ..<13: return "battery.0percent"
            case ..<38: return "battery.25percent"
            case ..<63: return "battery.50percent"
            case ..<88: return "battery.75percent"
            default: return "battery.100percent"
            }
        }
    }

    @Published var names: [String] = []
    @Published var battery: Battery?
    var onMove: ((Int) -> Void)?
    var onPrimary: (() -> Void)?
    var onOptions: (() -> Void)?

    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var lastStickMove = Date.distantPast

    init() {
        let center = NotificationCenter.default
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshControllers() }
            })
        }
        GCController.startWirelessControllerDiscovery {}
        refreshControllers()
        battery = Self.readBattery()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.battery = Self.readBattery() }
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        timer?.invalidate()
    }

    private func refreshControllers() {
        let controllers = GCController.controllers()
        names = controllers.map { $0.vendorName ?? "Controller" }
        for controller in controllers {
            guard let pad = controller.extendedGamepad else { continue }
            pad.dpad.left.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { self?.onMove?(-1) } }
            pad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { self?.onMove?(1) } }
            pad.leftThumbstick.xAxis.valueChangedHandler = { [weak self] _, value in
                guard let self, abs(value) > 0.6, Date().timeIntervalSince(self.lastStickMove) > 0.28 else { return }
                self.lastStickMove = Date()
                self.onMove?(value > 0 ? 1 : -1)
            }
            pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { self?.onPrimary?() } }
            pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { self?.onOptions?() } }
            pad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { self?.onOptions?() } }
        }
    }

    static func readBattery() -> Battery? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            let charging = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return Battery(percent: current * 100 / maximum, charging: charging)
        }
        return nil
    }
}
#endif
