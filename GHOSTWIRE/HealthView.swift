import SwiftUI

/// The Health card's parts, made from the server's checks the same way the
/// web interface does: the public address per IP family (from its uplink and
/// public address checks), then one tile per other check with a plain-word
/// status, the raw setting and, when it fails, what is wrong.
nonisolated struct HealthParts {
    struct Address: Hashable {
        let label: String
        let ok: Bool
        let value: String
        let note: String?
        let mono: Bool
    }

    struct Tile: Hashable {
        var label: String
        let ok: Bool
        var status: String
        var raw: String?
        var problem: String?
        var applied: Date? // shown as "3 min ago" in place of the status
    }

    let addresses: [Address]
    let tiles: [Tile]
    let failing: Int
    let total: Int

    init(_ checks: [HealthCheck]) {
        let by = Dictionary(checks.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var addresses: [Address] = []
        for fam in ["IPv4", "IPv6"] {
            guard let up = by[fam + " uplink"] else { continue }
            let pub = by["Public " + fam]
            // "192.168.1.20 (private, behind NAT)": the address, then a note.
            var value = pub?.detail ?? up.detail, note: String?
            if let pub, pub.ok, let open = pub.detail.range(of: " ("), pub.detail.hasSuffix(")") {
                value = String(pub.detail[..<open.lowerBound])
                note = String(pub.detail[open.upperBound...].dropLast())
            }
            addresses.append(Address(label: "Public " + fam + (up.ok ? " · " + up.detail : ""),
                                     ok: up.ok && (pub?.ok ?? true), value: value, note: note, mono: pub?.ok ?? false))
        }

        func sysctl(_ d: String) -> String {
            d.replacing(/^net\.ipv[46]\.(conf\.)?/, with: "")
        }
        let addressChecks: Set<String> = ["IPv4 uplink", "IPv6 uplink", "Public IPv4", "Public IPv6"]
        tiles = checks.filter { !addressChecks.contains($0.name) }.map { c in
            var t = Tile(label: c.name, ok: c.ok, status: c.ok ? "OK" : "Problem", raw: nil, problem: c.ok ? nil : c.detail)
            switch c.name {
            case "WireGuard interface":
                t.status = c.detail
                t.problem = nil
            case "IPv4 forwarding", "IPv6 forwarding":
                t.status = c.ok ? "On" : "Off"
                t.raw = sysctl(c.detail)
                t.problem = nil
            case "IPv6 router announcements":
                let parts = c.detail.components(separatedBy: ": ")
                t.label = "Router announcements"
                t.status = !c.ok ? "Ignored" : parts[0].hasSuffix("=0") ? "Not used" : "Accepted"
                t.raw = sysctl(parts[0])
                t.problem = c.ok || parts.count < 2 ? nil : parts.dropFirst().joined(separator: ": ")
            case "nftables rules":
                t.status = c.ok ? "Present" : "Missing"
                if c.detail.hasPrefix("table ") {
                    t.raw = c.detail.replacing(#/ (present|missing)$/#, with: "")
                    t.problem = nil
                }
            case "Last apply":
                if c.ok {
                    let iso = c.detail.hasPrefix("applied ") ? String(c.detail.dropFirst(8)) : c.detail
                    t.applied = try? Date(iso, strategy: .iso8601)
                    t.status = c.detail
                } else {
                    t.status = "Failed"
                }
            case "Latency check":
                t.status = c.ok ? "Tunnel ping works" : "Failing"
            default:
                break
            }
            return t
        }
        self.addresses = addresses
        failing = checks.filter { !$0.ok }.count
        total = checks.count
    }

    var summary: String {
        failing > 0 ? "\(failing) of \(total) checks failing" : "All \(total) checks pass"
    }
}

struct HealthGrid: View {
    let parts: HealthParts

    var body: some View {
        VStack(spacing: 10) {
            ForEach(parts.addresses, id: \.self) { AddressTile(address: $0) }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10, alignment: .top),
                                GridItem(.flexible(), spacing: 10, alignment: .top)], spacing: 10) {
                ForEach(parts.tiles, id: \.self) { CheckTile(tile: $0) }
            }
        }
    }
}

/// Spoken as one element: "OK: Public IPv4 · via eth0, 178.105.69.179".
private func spoken(_ ok: Bool, _ parts: [String?]) -> String {
    (ok ? "OK: " : "Problem: ") + parts.compactMap { $0 }.joined(separator: ", ")
}

private struct AddressTile: View {
    let address: HealthParts.Address

    private var valueText: Text {
        let a = address
        let font: Font = a.mono ? .mono(.title3, weight: .medium) : .subheadline.weight(.medium)
        let value = Text(a.value).font(font).foregroundStyle(a.ok ? Color.gwText : Color.gwErrInk)
        guard let note = a.note else { return value }
        return value + Text("  " + note).font(.caption).foregroundStyle(Color.gwText2)
    }

    var body: some View {
        let a = address
        let border: Color = a.ok ? .clear : Color.gwErrInk.opacity(0.35)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(a.ok ? Color.gwGood : Color.gwBad).frame(width: 8, height: 8)
                Text(a.label).font(.caption).foregroundStyle(Color.gwText2)
            }
            valueText.textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(a.ok ? Color.gwSurface : Color.gwErrBg, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(a.ok, [a.label, a.value, a.note]))
    }
}

private struct CheckTile: View {
    let tile: HealthParts.Tile

    var body: some View {
        let t = tile
        let status = t.applied.map { ago($0) } ?? t.status
        let border: Color = t.ok ? Color.gwLine : Color.gwErrInk.opacity(0.35)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(t.label).font(.caption).foregroundStyle(Color.gwText2)
                Spacer(minLength: 0)
                Circle().fill(t.ok ? Color.gwGood : Color.gwBad).frame(width: 8, height: 8)
            }
            Text(status).font(.subheadline.weight(.medium))
                .foregroundStyle(t.ok ? Color.gwText : Color.gwErrInk)
            if let raw = t.raw {
                Text(raw).font(.mono(.caption2)).foregroundStyle(Color.gwText2)
            }
            if let p = t.problem {
                Text(p).font(.caption).foregroundStyle(Color.gwErrInk)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(t.ok ? Color.gwSurface : Color.gwErrBg, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(t.ok, [t.label, status, t.raw, t.problem]))
    }
}
