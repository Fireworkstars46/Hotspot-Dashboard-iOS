import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var network = NetworkStatus()
    @StateObject private var bonjour = BonjourScanner()

    var body: some View {
        TabView {
            NavigationView { DashboardView(network: network) }
                .tabItem { Label("Dashboard", systemImage: "personalhotspot") }

            NavigationView { InterfacesView(network: network) }
                .tabItem { Label("Interfaces", systemImage: "network") }

            NavigationView { DiscoveryView(scanner: bonjour) }
                .tabItem { Label("Discovery", systemImage: "dot.radiowaves.left.and.right") }

            NavigationView { LimitsView() }
                .tabItem { Label("Limits", systemImage: "lock.shield") }
        }
    }
}

struct DashboardView: View {
    @ObservedObject var network: NetworkStatus
    @AppStorage("manualHotspotName") private var manualHotspotName = ""

    var body: some View {
        List {
            Section("Personal Hotspot") {
                LabeledContent("Hotspot name") {
                    Text(manualHotspotName.isEmpty ? "Enter below" : manualHotspotName)
                }
                TextField("Your iPhone hotspot name", text: $manualHotspotName)
                    .textInputAutocapitalization(.words)
                LabeledContent("Actual connected-client count", value: "Blocked by iOS")
                Text("Apple uses the iPhone's device name as the Personal Hotspot name, but iOS 16+ normally gives apps only the generic device name. Save your real hotspot name here once and this dashboard will remember it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Connection") {
                LabeledContent("Internet", value: network.isOnline ? "Online" : "Offline")
                LabeledContent("Current route", value: network.connection)
                LabeledContent("IPv4", value: network.supportsIPv4 ? "Yes" : "No")
                LabeledContent("IPv6", value: network.supportsIPv6 ? "Yes" : "No")
                LabeledContent("DNS available", value: network.supportsDNS ? "Yes" : "No")
                LabeledContent("Metered / expensive", value: network.expensive ? "Yes" : "No")
                LabeledContent("Low Data Mode", value: network.constrained ? "Yes" : "No")
            }

            Section("Live traffic") {
                LabeledContent("Download", value: formatRate(network.downloadPerSecond))
                LabeledContent("Upload", value: formatRate(network.uploadPerSecond))
                Text("Rates use the current primary interface and update about once per second.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Internet address") {
                LabeledContent("Public IP", value: network.publicIP)
                Button(network.publicIPBusy ? "Checking…" : "Refresh public IP") {
                    network.refreshPublicIP()
                }
                .disabled(network.publicIPBusy)
                Text("Public IP lookup contacts api64.ipify.org only when you press Refresh.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("This iPhone") {
                LabeledContent("Model", value: DeviceInfo.modelName)
                LabeledContent("Hardware ID", value: DeviceInfo.machineIdentifier)
                LabeledContent("iOS", value: UIDevice.current.systemVersion)
                LabeledContent("App-visible name", value: UIDevice.current.name)
                LabeledContent("Cellular radio", value: DeviceInfo.radioTechnology)
            }

            Section("Best hotspot clue") {
                let bridgeInterfaces = network.interfaces.filter { $0.name.hasPrefix("bridge") }
                if bridgeInterfaces.isEmpty {
                    Text("No bridge interface is visible right now.")
                } else {
                    ForEach(bridgeInterfaces) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.headline)
                            Text("RX \(formatBytes(item.receivedBytes)) • TX \(formatBytes(item.sentBytes))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !item.addresses.isEmpty {
                                Text(item.addresses.joined(separator: " • "))
                                    .font(.caption2.monospaced())
                            }
                        }
                    }
                }
                Text("A bridge can be related to tethering/hotspot networking, but this is an observation only—not an official hotspot-on indicator or client count.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Hotspot Dashboard")
        .refreshable { network.refreshInterfaces() }
    }
}

struct InterfacesView: View {
    @ObservedObject var network: NetworkStatus

    var body: some View {
        List {
            Section {
                Text("This is the raw network-interface view iOS allows the app to inspect. Bridge and cellular interfaces are especially useful when watching hotspot traffic.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(network.interfaces) { item in
                Section("\(item.friendlyName) — \(item.name)") {
                    LabeledContent("Received", value: formatBytes(item.receivedBytes))
                    LabeledContent("Sent", value: formatBytes(item.sentBytes))
                    if item.addresses.isEmpty {
                        LabeledContent("Addresses", value: "None visible")
                    } else {
                        ForEach(item.addresses, id: \.self) { address in
                            Text(address).font(.system(.footnote, design: .monospaced))
                        }
                    }
                }
            }
        }
        .navigationTitle("Interfaces")
        .toolbar {
            Button { network.refreshInterfaces() } label: { Image(systemName: "arrow.clockwise") }
        }
    }
}

struct DiscoveryView: View {
    @ObservedObject var scanner: BonjourScanner

    var uniqueNames: Int { Set(scanner.services.map(\.name)).count }

    var body: some View {
        List {
            Section("Best-effort device discovery") {
                LabeledContent("Discoverable names", value: "\(uniqueNames)")
                LabeledContent("Bonjour services", value: "\(scanner.services.count)")
                Button(scanner.running ? "Stop discovery" : "Start discovery") {
                    scanner.running ? scanner.stop() : scanner.start()
                }
                Text("This can find devices/services that advertise themselves on the local network. It is NOT the official hotspot client list, so silent devices may be missing and one device can advertise several services.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if scanner.services.isEmpty {
                Section {
                    Text(scanner.running ? "Scanning… Keep the app open for a little while." : "Start discovery to look for visible Bonjour devices/services.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section("Found") {
                    ForEach(scanner.services) { service in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(service.name).font(.headline)
                            Text(service.type).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(service.domain).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Discovery")
    }
}

struct LimitsView: View {
    var body: some View {
        List {
            Section("What this app can show") {
                Label("Current network route and status", systemImage: "checkmark.circle")
                Label("IPv4 / IPv6 / DNS capability", systemImage: "checkmark.circle")
                Label("Raw interface names and IP addresses", systemImage: "checkmark.circle")
                Label("Per-interface received/sent byte counters", systemImage: "checkmark.circle")
                Label("Live primary-interface traffic rate", systemImage: "checkmark.circle")
                Label("Exact iPhone hardware model", systemImage: "checkmark.circle")
                Label("Cellular radio type when iOS supplies it", systemImage: "checkmark.circle")
                Label("Best-effort Bonjour discovery", systemImage: "checkmark.circle")
            }

            Section("What Apple blocks") {
                Label("Official Personal Hotspot on/off state", systemImage: "xmark.circle")
                Label("Exact connected-device count", systemImage: "xmark.circle")
                Label("Complete hotspot client names / MAC addresses", systemImage: "xmark.circle")
                Label("Kick or block one hotspot client", systemImage: "xmark.circle")
                Label("Per-client hotspot data usage", systemImage: "xmark.circle")
                Label("User-assigned iPhone name without special entitlement", systemImage: "xmark.circle")
            }

            Section("Why") {
                Text("iOS doesn't provide a general-purpose Wi‑Fi scanning/Personal Hotspot management API to ordinary apps. This app therefore exposes the useful public networking information that remains available and labels experimental clues clearly.")
                    .font(.footnote)
            }
        }
        .navigationTitle("iOS Limits")
    }
}
