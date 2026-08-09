import Foundation
import Network
import UIKit
import CoreTelephony
import Darwin

struct InterfaceSnapshot: Identifiable, Hashable {
    let id: String
    let name: String
    let addresses: [String]
    let receivedBytes: UInt64
    let sentBytes: UInt64

    var friendlyName: String {
        if name == "en0" { return "Wi‑Fi" }
        if name.hasPrefix("pdp_ip") { return "Cellular" }
        if name.hasPrefix("bridge") { return "Bridge / possible hotspot" }
        if name.hasPrefix("lo") { return "Loopback" }
        if name.hasPrefix("utun") { return "VPN / tunnel" }
        if name.hasPrefix("awdl") { return "Apple Wireless Direct Link" }
        if name.hasPrefix("llw") { return "Low-latency Wi‑Fi" }
        return "System interface"
    }
}

enum InterfaceReader {
    static func read() -> [InterfaceSnapshot] {
        var addressPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressPointer) == 0, let first = addressPointer else { return [] }
        defer { freeifaddrs(addressPointer) }

        var addresses: [String: Set<String>] = [:]
        var counters: [String: (rx: UInt64, tx: UInt64)] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = first

        while let current = pointer {
            let interface = current.pointee
            let name = String(cString: interface.ifa_name)

            if let sa = interface.ifa_addr {
                let family = Int32(sa.pointee.sa_family)
                if family == AF_INET || family == AF_INET6 {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let length = socklen_t(sa.pointee.sa_len)
                    if getnameinfo(sa, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let value = String(cString: host)
                        addresses[name, default: []].insert(value)
                    }
                }

                if family == AF_LINK, let raw = interface.ifa_data {
                    let data = raw.assumingMemoryBound(to: if_data.self).pointee
                    counters[name] = (UInt64(data.ifi_ibytes), UInt64(data.ifi_obytes))
                }
            }
            pointer = interface.ifa_next
        }

        let names = Set(addresses.keys).union(counters.keys)
        return names.map { name in
            let bytes = counters[name] ?? (0, 0)
            return InterfaceSnapshot(
                id: name,
                name: name,
                addresses: Array(addresses[name] ?? []).sorted(),
                receivedBytes: bytes.rx,
                sentBytes: bytes.tx
            )
        }.sorted { a, b in
            let rank: (String) -> Int = { value in
                if value == "en0" { return 0 }
                if value.hasPrefix("pdp_ip") { return 1 }
                if value.hasPrefix("bridge") { return 2 }
                if value.hasPrefix("utun") { return 3 }
                if value.hasPrefix("awdl") { return 4 }
                if value.hasPrefix("lo") { return 9 }
                return 5
            }
            let ra = rank(a.name), rb = rank(b.name)
            return ra == rb ? a.name < b.name : ra < rb
        }
    }
}

final class NetworkStatus: ObservableObject {
    @Published var isOnline = false
    @Published var connection = "Checking…"
    @Published var expensive = false
    @Published var constrained = false
    @Published var supportsIPv4 = false
    @Published var supportsIPv6 = false
    @Published var supportsDNS = false
    @Published var interfaces: [InterfaceSnapshot] = []
    @Published var downloadPerSecond: Double = 0
    @Published var uploadPerSecond: Double = 0
    @Published var publicIP = "Not checked"
    @Published var publicIPBusy = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "HotspotDashboard.NWPath")
    private var timer: Timer?
    private var previousPrimary: InterfaceSnapshot?
    private var previousDate = Date()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isOnline = path.status == .satisfied
                self.expensive = path.isExpensive
                self.constrained = path.isConstrained
                self.supportsIPv4 = path.supportsIPv4
                self.supportsIPv6 = path.supportsIPv6
                self.supportsDNS = path.supportsDNS

                if path.usesInterfaceType(.wifi) { self.connection = "Wi‑Fi" }
                else if path.usesInterfaceType(.cellular) { self.connection = "Cellular" }
                else if path.usesInterfaceType(.wiredEthernet) { self.connection = "Ethernet" }
                else if path.usesInterfaceType(.loopback) { self.connection = "Loopback" }
                else if path.status == .satisfied { self.connection = "Other" }
                else { self.connection = "Offline" }
            }
        }
        monitor.start(queue: queue)
        refreshInterfaces()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshInterfaces()
        }
    }

    deinit {
        timer?.invalidate()
        monitor.cancel()
    }

    func refreshInterfaces() {
        let now = Date()
        let snapshots = InterfaceReader.read()
        let primary = choosePrimary(from: snapshots)
        let elapsed = max(now.timeIntervalSince(previousDate), 0.25)

        if let old = previousPrimary, let new = primary, old.name == new.name {
            downloadPerSecond = new.receivedBytes >= old.receivedBytes ? Double(new.receivedBytes - old.receivedBytes) / elapsed : 0
            uploadPerSecond = new.sentBytes >= old.sentBytes ? Double(new.sentBytes - old.sentBytes) / elapsed : 0
        } else {
            downloadPerSecond = 0
            uploadPerSecond = 0
        }

        previousPrimary = primary
        previousDate = now
        interfaces = snapshots
    }

    private func choosePrimary(from snapshots: [InterfaceSnapshot]) -> InterfaceSnapshot? {
        if connection == "Wi‑Fi", let wifi = snapshots.first(where: { $0.name == "en0" }) { return wifi }
        if connection == "Cellular", let cell = snapshots.first(where: { $0.name.hasPrefix("pdp_ip") }) { return cell }
        return snapshots.first(where: { $0.name == "en0" }) ?? snapshots.first(where: { $0.name.hasPrefix("pdp_ip") })
    }

    func refreshPublicIP() {
        guard !publicIPBusy else { return }
        publicIPBusy = true
        guard let url = URL(string: "https://api64.ipify.org") else {
            publicIPBusy = false
            return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.publicIPBusy = false }
                if let data, let text = String(data: data, encoding: .utf8), !text.isEmpty {
                    self.publicIP = text.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    self.publicIP = error == nil ? "Unavailable" : "Request failed"
                }
            }
        }.resume()
    }
}

enum DeviceInfo {
    static var machineIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        return mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
    }

    static var modelName: String {
        switch machineIdentifier {
        case "iPhone10,1", "iPhone10,4": return "iPhone 8"
        case "iPhone10,2", "iPhone10,5": return "iPhone 8 Plus"
        case "iPhone10,3", "iPhone10,6": return "iPhone X"
        case "iPhone11,2": return "iPhone XS"
        case "iPhone11,4", "iPhone11,6": return "iPhone XS Max"
        case "iPhone11,8": return "iPhone XR"
        case "iPhone12,1": return "iPhone 11"
        case "iPhone12,3": return "iPhone 11 Pro"
        case "iPhone12,5": return "iPhone 11 Pro Max"
        case "iPhone12,8": return "iPhone SE (2nd generation)"
        case "iPhone13,1": return "iPhone 12 mini"
        case "iPhone13,2": return "iPhone 12"
        case "iPhone13,3": return "iPhone 12 Pro"
        case "iPhone13,4": return "iPhone 12 Pro Max"
        case "iPhone14,4": return "iPhone 13 mini"
        case "iPhone14,5": return "iPhone 13"
        case "iPhone14,2": return "iPhone 13 Pro"
        case "iPhone14,3": return "iPhone 13 Pro Max"
        case "iPhone14,6": return "iPhone SE (3rd generation)"
        case "iPhone14,7": return "iPhone 14"
        case "iPhone14,8": return "iPhone 14 Plus"
        case "iPhone15,2": return "iPhone 14 Pro"
        case "iPhone15,3": return "iPhone 14 Pro Max"
        case "iPhone15,4": return "iPhone 15"
        case "iPhone15,5": return "iPhone 15 Plus"
        case "iPhone16,1": return "iPhone 15 Pro"
        case "iPhone16,2": return "iPhone 15 Pro Max"
        case "iPhone17,3": return "iPhone 16"
        case "iPhone17,4": return "iPhone 16 Plus"
        case "iPhone17,1": return "iPhone 16 Pro"
        case "iPhone17,2": return "iPhone 16 Pro Max"
        case "iPhone17,5": return "iPhone 16e"
        default:
            if machineIdentifier.hasPrefix("i386") || machineIdentifier.hasPrefix("x86_64") || machineIdentifier.hasPrefix("arm64") {
                return "iPhone Simulator"
            }
            return machineIdentifier
        }
    }

    static var radioTechnology: String {
        let info = CTTelephonyNetworkInfo()
        guard let value = info.serviceCurrentRadioAccessTechnology?.values.first else { return "Unavailable" }
        if value.contains("NRNSA") { return "5G NSA" }
        if value.contains("NR") { return "5G" }
        if value.contains("LTE") { return "LTE / 4G" }
        if value.contains("WCDMA") || value.contains("HSDPA") || value.contains("HSUPA") { return "3G" }
        if value.contains("Edge") { return "EDGE" }
        if value.contains("GPRS") { return "GPRS" }
        return value
    }
}

struct DiscoveredService: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let domain: String
}

final class BonjourScanner: ObservableObject {
    @Published var services: [DiscoveredService] = []
    @Published var running = false

    private var browsers: [NWBrowser] = []
    private let queue = DispatchQueue(label: "HotspotDashboard.Bonjour")
    private let types = ["_http._tcp", "_https._tcp", "_ssh._tcp", "_smb._tcp", "_airplay._tcp", "_raop._tcp", "_workstation._tcp"]

    func start() {
        stop()
        running = true
        for type in types {
            let browser = NWBrowser(for: .bonjour(type: type, domain: nil), using: .tcp)
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.merge(results: results)
            }
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state {
                    DispatchQueue.main.async { self?.running = !((self?.browsers.isEmpty) ?? true) }
                }
            }
            browsers.append(browser)
            browser.start(queue: queue)
        }
    }

    func stop() {
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        DispatchQueue.main.async {
            self.running = false
        }
    }

    private func merge(results: Set<NWBrowser.Result>) {
        let mapped: [DiscoveredService] = results.compactMap { result in
            if case let .service(name, type, domain, _) = result.endpoint {
                return DiscoveredService(id: "\(name)|\(type)|\(domain)", name: name, type: type, domain: domain)
            }
            return nil
        }

        DispatchQueue.main.async {
            var dictionary = Dictionary(uniqueKeysWithValues: self.services.map { ($0.id, $0) })
            for item in mapped { dictionary[item.id] = item }
            self.services = dictionary.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }
}

func formatBytes(_ value: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .binary)
}

func formatRate(_ value: Double) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .binary
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.includesUnit = true
    return "\(formatter.string(fromByteCount: Int64(value)))/s"
}
