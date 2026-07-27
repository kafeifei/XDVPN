import CoreLocation
@preconcurrency import CoreWLAN
import Foundation
import XDVPNCore

@MainActor
final class WiFiSSIDReader: NSObject, CLLocationManagerDelegate {
    var onAuthorizationChanged: (() -> Void)?

    private let locationManager = CLLocationManager()

    override init() {
        super.init()
        locationManager.delegate = self
    }

    var isLocationPermissionRequired: Bool {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return false
        default:
            return true
        }
    }

    func currentSSID() -> String? {
        ObservedWiFiSSID.normalized(CWWiFiClient.shared().interface()?.ssid())
    }

    nonisolated static func currentSSIDFromSystemProfiler() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPAirPortDataType", "-json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let groups = root["SPAirPortDataType"] as? [[String: Any]] else {
            return nil
        }

        for group in groups {
            guard let interfaces = group["spairport_airport_interfaces"] as? [[String: Any]] else {
                continue
            }
            for iface in interfaces {
                guard let current = iface["spairport_current_network_information"] as? [String: Any],
                      let ssid = current["_name"] as? String else {
                    continue
                }
                if let normalized = ObservedWiFiSSID.normalized(ssid) {
                    return normalized
                }
            }
        }
        return nil
    }

    func requestLocationPermissionIfNeeded() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.onAuthorizationChanged?()
        }
    }
}
