import Contacts
import CoreLocation
import Foundation

// One-shot street address for where the device is now. CoreLocation finds the position on the device;
// turning it into an address uses Apple's geocoding service, which receives the coordinates only.
@MainActor final class LocationAddress: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAddress()
    private let manager = CLLocationManager()
    private var waiting: [CheckedContinuation<CLLocation?, Never>] = []
    private var prefetched: (task: Task<String?, Never>, started: Date)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    // Starts a lookup now (when a scan begins) so the address is ready when the scan is saved.
    func prefetch() {
        guard Setting.bool(Setting.autoAddress, default: true) else { return }
        prefetched = (Task { await self.lookUp() }, Date())
    }
    // The prefetched address if it's recent, otherwise a fresh lookup; nil if unavailable or denied.
    func addressForNewScan() async -> String? {
        guard Setting.bool(Setting.autoAddress, default: true) else { return nil }
        if let p = prefetched, Date().timeIntervalSince(p.started) < 900 { prefetched = nil; return await p.task.value }
        return await lookUp()
    }

    func lookUp() async -> String? {
        guard let location = await currentLocation() else { return nil }
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return nil }
        if let found = placemark.postalAddress {
            // The country is left off for addresses in the device's own region.
            let postal = found.mutableCopy() as! CNMutablePostalAddress
            if postal.isoCountryCode.uppercased() == (Locale.current.region?.identifier ?? "").uppercased() { postal.country = "" }
            let text = CNPostalAddressFormatter.string(from: postal, style: .mailingAddress)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
            if !text.isEmpty { return String(text.prefix(300)) }
        }
        let parts = [placemark.subThoroughfare.map { "\($0) \(placemark.thoroughfare ?? "")" } ?? placemark.thoroughfare, placemark.locality, placemark.administrativeArea, placemark.postalCode]
        let text = parts.compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: ", ")
        return text.isEmpty ? nil : String(text.prefix(300))
    }

    private func currentLocation() async -> CLLocation? {
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        default: break
        }
        // A fix from the last minute is good enough and avoids waiting.
        if let recent = manager.location, Date().timeIntervalSince(recent.timestamp) < 60, recent.horizontalAccuracy <= 100 { return recent }
        return await withCheckedContinuation { continuation in
            waiting.append(continuation)
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() } else { manager.requestLocation() }
            // Never hold up saving a scan for long.
            Task { [weak self] in try? await Task.sleep(for: .seconds(20)); self?.finish(nil) }
        }
    }
    private func finish(_ location: CLLocation?) {
        let pending = waiting; waiting = []
        pending.forEach { $0.resume(returning: location) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: if !self.waiting.isEmpty { manager.requestLocation() }
            case .denied, .restricted: self.finish(nil)
            default: break
            }
        }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.finish(last) }
    }
    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.finish(nil) }
    }
}
