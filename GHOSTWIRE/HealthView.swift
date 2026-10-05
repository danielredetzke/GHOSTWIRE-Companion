import SwiftUI

/// The Health card's parts, made from the server's checks the same way the
/// web interface does: the public address per IP family (from its uplink and
/// public address checks) and, beside them, one row per other check with a
/// plain-word status, the raw setting and, when it fails, what is wrong.
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

/// Addresses beside the checks when there is room (iPad), stacked above
/// them otherwise.
struct HealthGrid: View {
    let parts: HealthParts
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            HStack(alignment: .top, spacing: 12) {
                addresses.frame(maxWidth: 380, maxHeight: .infinity)
                CheckList(tiles: parts.tiles, wide: true).frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 10) {
                addresses
                CheckList(tiles: parts.tiles, wide: false)
            }
        }
    }

    private var addresses: some View {
        VStack(spacing: sizeClass == .regular ? 12 : 10) {
            ForEach(parts.addresses, id: \.self) { AddressTile(address: $0) }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(a.ok ? Color.gwSurface : Color.gwErrBg, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(border))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(a.ok, [a.label, a.value, a.note]))
    }
}

/// The checks as rows in one bordered list.
private struct CheckList: View {
    let tiles: [HealthParts.Tile]
    let wide: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(tiles.enumerated()), id: \.element) { i, t in
                if i > 0 { Rectangle().fill(Color.gwLine).frame(height: 1) }
                CheckRow(tile: t, wide: wide)
            }
        }
        .background(Color.gwSurface, in: .rect(cornerRadius: 10))
        .clipShape(.rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.gwLine))
    }
}

/// One check: name, then the status with its raw setting right after it. On
/// a wide layout the name has its own column; otherwise it sits above.
private struct CheckRow: View {
    let tile: HealthParts.Tile
    let wide: Bool

    var body: some View {
        let t = tile
        let status = t.applied.map { ago($0) } ?? t.status
        let name = Text(t.label).font(.caption).foregroundStyle(Color.gwText2)
        let value = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(status).font(.subheadline.weight(.medium))
                .foregroundStyle(t.ok ? Color.gwText : Color.gwErrInk)
            if let raw = t.raw {
                Text(raw).font(.mono(.caption2)).foregroundStyle(Color.gwText2)
            }
        }
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle().fill(t.ok ? Color.gwGood : Color.gwBad).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                if wide {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        name.frame(width: 170, alignment: .leading)
                        value
                    }
                } else {
                    name
                    value
                }
                if let p = t.problem {
                    Text(p).font(.caption).foregroundStyle(Color.gwErrInk)
                        .padding(.leading, wide ? 182 : 0)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(t.ok ? Color.clear : Color.gwErrBg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken(t.ok, [t.label, status, t.raw, t.problem]))
    }
}
