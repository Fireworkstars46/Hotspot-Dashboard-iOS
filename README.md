# Hotspot Dashboard (iOS 16+)

A free SwiftUI iPhone app that exposes as much useful Personal-Hotspot-adjacent information as ordinary public iOS APIs allow.

## Included
- Online/offline + current route (Wi-Fi/cellular/etc.)
- IPv4, IPv6, DNS, metered/expensive, Low Data Mode
- Raw iOS network interfaces and IP addresses
- Per-interface RX/TX counters
- Live primary-interface download/upload rate
- Bridge-interface highlighting as a *possible* hotspot/tethering clue
- Exact iPhone hardware identifier/model mapping, including iPhone 8 Plus
- Cellular radio technology when supplied by iOS
- Manual remembered Hotspot name (because iOS 16+ restricts the real user-assigned device name)
- Public IP lookup only when requested
- Best-effort Bonjour discovery for visible local devices/services
- Clear screen listing what iOS blocks

## Important iOS limitation
Apple does not expose an ordinary public API for the official Personal Hotspot client list. The app therefore cannot guarantee an exact connected-device count, enumerate every client, disconnect one client, or report per-client traffic.

## IPA build
GitHub Actions builds an unsigned `HotspotDashboard.ipa` that can be signed and installed with Sideloadly.

The project itself has no paid SDKs or third-party dependencies.
