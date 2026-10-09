import Foundation

// Types mirror the JSON of GHOSTWIRE's /api/v1. Traffic is from the peer's
// point of view: down is what the peer downloaded, up what it uploaded.

nonisolated struct Me: Decodable {
    let name: String
    let isAdmin: Bool
    let scope: String
    let version: String
    let updateAvailable: String? // newer release, nil when up to date
}

nonisolated struct HealthCheck: Decodable, Hashable {
    let name: String
    let ok: Bool
    let detail: String
}

nonisolated struct PeerCounts: Decodable {
    let total, enabled, online, disabled, never: Int
}

nonisolated struct Traffic: Decodable {
    let down: Int64
    let up: Int64
}

nonisolated struct Status: Decodable {
    let version: String
    let interface: String
    let listenPort: Int
    let endpoint: String
    let ipv4: String
    let ipv6: String
    let ipv6Enabled: Bool
    let capacity: Int
    let started: Date
    let healthy: Bool
    let checks: [HealthCheck]
    let peers: PeerCounts
    let traffic24h: Traffic
    let traffic30d: Traffic
    let topPeer30d: String
    let visitor: Visitor? // nil on servers before v0.9.0
}

/// Whether the device asking is behind the VPN. Behind it, websites see the
/// server's address, so ip is then the server's.
nonisolated struct Visitor: Decodable {
    let `protected`: Bool
    let ip: String
    let serverIP: String  // empty when the endpoint does not resolve
    let peer: PeerRef?    // the peer whose tunnel the request came through
    let location: GeoInfo? // of ip, when not protected
}

nonisolated struct PeerRef: Decodable, Hashable {
    let id: String
    let name: String
}

/// The last minutes of speeds, from /live/stream. The first message holds
/// the whole history, later ones one new step each.
nonisolated struct LiveSpeeds: Decodable {
    let step: Int  // seconds
    let size: Int  // points the server keeps
    let points: [SpeedPoint]
}

/// One step: per peer ID, download and upload in bits per second.
nonisolated struct SpeedPoint: Decodable, Identifiable {
    let t: Int64
    let peers: [String: [Int64]]
    var id: Int64 { t }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }

    func rate(_ peerID: String) -> (down: Int64, up: Int64) {
        guard let v = peers[peerID], v.count == 2 else { return (0, 0) }
        return (v[0], v[1])
    }

    var total: (down: Int64, up: Int64) {
        peers.values.reduce((Int64(0), Int64(0))) { a, v in v.count == 2 ? (a.0 + v[0], a.1 + v[1]) : a }
    }
}

nonisolated struct StatPoint: Decodable, Identifiable, Hashable {
    let t: Int64
    let down: Int64
    let up: Int64
    var id: Int64 { t }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(t)) }
}

nonisolated struct StatsResponse: Decodable {
    let range: String
    let points: [StatPoint]
}

nonisolated struct PeerStats: Decodable, Hashable {
    let online: Bool
    let lastHandshake: Date?
    let endpoint: String
    let down24h, up24h, down30d, up30d, downTotal, upTotal: Int64
    let location: GeoInfo?
    let latency: LatencyView?  // nil = never pinged
}

/// Country and network of an address, from the server's DB-IP lookup.
nonisolated struct GeoInfo: Decodable, Hashable {
    let country: String?
    let countryName: String?
    let asn: Int?
    let network: String?

    /// "Germany · Deutsche Telekom AG" or "Local network".
    var label: String {
        [countryName ?? country, network].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// One row of a peer's connection history.
nonisolated struct ConnSession: Decodable, Identifiable, Hashable {
    let start: Date
    let end: Date
    let open: Bool
    let seconds: Int64
    let endpoint: String
    let ip: String
    let geo: GeoInfo?
    let down: Int64
    let up: Int64
    var id: String { "\(start.timeIntervalSince1970)-\(ip)" }
}

nonisolated struct SessionsResponse: Decodable {
    let sessions: [ConnSession]
}

nonisolated struct Peer: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let note: String
    let enabled: Bool
    let publicKey: String
    let hasPresharedKey: Bool
    let ipv4: String
    let ipv6: String?
    let dns: [String]?          // nil = server default
    let allowedIPs: [String]?   // nil = server default
    let keepalive: Int?         // nil = server default
    let effectiveDNS: [String]
    let effectiveAllowedIPs: [String]
    let effectiveKeepalive: Int
    let latencyCheck: String    // off | active | always
    let created: Date
    let configIssued: Date?
    let setup: SetupInfo?       // pending setup link, nil if none
    let stats: PeerStats
}

/// A pending setup link as peer lists show it. The link itself is not in it.
nonisolated struct SetupInfo: Decodable, Hashable {
    let expires: Date
    let expired: Bool
    let pinRequired: Bool
    let pinFails: Int
}

nonisolated struct PeerList: Decodable {
    let peers: [Peer]
    let capacity: Int
    let network: String
}

nonisolated struct PeerResult: Decodable {
    let peer: Peer
    let applyError: String
}

/// A freshly issued client config. The private key exists only here.
nonisolated struct IssuedConfig: Decodable, Identifiable {
    let peer: Peer
    let config: String
    let qr: String?
    let includesPrivateKey: Bool
    let applyError: String
    var id: String { peer.id + peer.publicKey }
}

/// A setup link for the admin to send. It sets up a device once.
nonisolated struct SetupSecret: Decodable, Hashable {
    let url: String
    let path: String
    let pin: String?
    let expires: Date
    let qr: String
}

/// The answer to creating a peer or issuing a config with a setup link.
nonisolated struct LinkCreated: Decodable {
    let peer: Peer
    let setup: SetupSecret
    let applyError: String
}

/// A config shown now, or a setup link to send.
enum IssueOutcome: Identifiable {
    case config(IssuedConfig)
    case link(LinkCreated)

    var id: String {
        switch self {
        case .config(let c): c.id
        case .link(let l): l.setup.path
        }
    }

    var peer: Peer {
        switch self {
        case .config(let c): c.peer
        case .link(let l): l.peer
        }
    }

    var applyError: String {
        switch self {
        case .config(let c): c.applyError
        case .link(let l): l.applyError
        }
    }
}

nonisolated struct PeerOnly: Decodable {
    let peer: Peer
}

/// The DNS preset the web interface offers.
let quad9DNS = ["9.9.9.9", "149.112.112.112"]

nonisolated struct ClientDefaults: Codable, Equatable {
    var dns: [String]
    var allowedIPs: [String]
    var keepalive: Int
}

/// Server settings as GET/PATCH /server use them.
nonisolated struct ServerConfig: Codable, Equatable {
    var interface: String
    var publicKey: String
    var keyCreated: Date
    var listenPort: Int
    var mtu: Int
    var ipv4: String
    var ipv6: String
    var ipv6Enabled: Bool
    var endpoint: String
    var endpointPort: Int
    var uplinkV4: String
    var uplinkV6: String
    var detectedUplinkV4: String
    var detectedUplinkV6: String
    var nat: Bool
    var peerToPeer: Bool
    var lanAccess: Bool
    var openPort: Bool
    var clientDefaults: ClientDefaults

    var networks: [String] { ipv6Enabled ? [ipv4, ipv6] : [ipv4] }
}

nonisolated struct ServerResult: Decodable {
    let server: ServerConfig
    let applyError: String
    let reissueNeeded: Bool?
}

nonisolated struct TLSSettings: Codable, Equatable {
    var mode: String
    var domain: String?
    var email: String?
    var staging: Bool?
    var certFile: String?
    var keyFile: String?
}

nonisolated struct WebSettings: Codable, Equatable {
    var listen: String
    var httpListen: String
    var tls: TLSSettings
    var sessionHours: Int
}

nonisolated struct LogSettings: Codable, Equatable {
    var level: String
    var maxSizeMB: Int
    var maxFiles: Int
}

nonisolated struct StatsSettings: Codable, Equatable {
    var hourlyHours: Int
    var dailyDays: Int
    var geoip: Bool?
}

nonisolated struct DecoySettings: Codable, Equatable {
    var enabled: Bool
    var page: String
}

nonisolated struct GeoStatus: Decodable {
    let enabled: Bool
    let updated: Date?
}

/// The DNS servers GHOSTWIRE uses for its own lookups. No servers: the
/// system resolver.
nonisolated struct DNSSettings: Decodable, Equatable {
    var servers: [String]
    var fallback: Bool    // ask the system resolver when none of the servers answers
    var system: [String]  // the nameservers in /etc/resolv.conf
}

/// What the DNS Test button found.
nonisolated struct DNSTestResult: Decodable {
    let name: String
    let answer: String
    let ms: Int
    let server: String
}

nonisolated struct Release: Decodable {
    let version: String
    let published: Date
    let notes: String // Markdown
    let url: String
}

/// The daily release check, as the settings and POST /updates/check show it.
nonisolated struct UpdateStatus: Decodable {
    let enabled: Bool
    let current: String
    let latest: Release?
    let available: Bool
    let checked: Date?
    let error: String?
    let lastOk: Date?
    let arch: String      // empty when no release file is built for the server
    let file: String?
    let fileUrl: String?
    let sumsUrl: String?
}

nonisolated struct AppSettings: Decodable {
    var web: WebSettings
    var log: LogSettings
    var stats: StatsSettings
    var decoy: DecoySettings? // nil on servers without the decoy
    var dns: DNSSettings?     // nil on servers before v0.11.0
    var updates: UpdateStatus?
    var fingerprint: String
    var logPath: String
    var geo: GeoStatus?
}

nonisolated struct SettingsResult: Decodable {
    let ok: Bool
    let restartRequired: Bool
}

nonisolated struct ApplyResult: Decodable {
    let applyError: String?
}

nonisolated struct DetectedIP: Decodable {
    let ip: String
}
