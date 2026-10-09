import SwiftUI

struct SettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var settings: AppSettings?
    @State private var web: WebSettings?
    @State private var log: LogSettings?
    @State private var stats: StatsSettings?
    @State private var decoy: DecoySettings?
    @State private var dns: DNSDraft?
    @State private var dnsResult: String?
    @State private var dnsError: String?
    @State private var testingDNS = false
    @State private var updates: UpdateStatus?
    @State private var checking = false
    @State private var copiedCommands = false
    @State private var error: String?
    @State private var busy = false
    @State private var offerRestart = false
    @State private var confirmRestart = false
    @State private var confirmShrink = false
    @State private var confirmDisconnect = false
    @State private var confirmDecoy = false
    @State private var serverName = ""

    private static let hourly: [(Int, String)] = [(24, "1 day"), (48, "2 days"), (168, "7 days"), (336, "14 days"), (744, "31 days")]
    private static let daily: [(Int, String)] = [(30, "30 days"), (90, "90 days"), (180, "6 months"), (400, "13 months"),
                                                 (730, "2 years"), (1825, "5 years"), (3660, "10 years")]

    var body: some View {
        NavigationStack {
            Form {
                deviceSection
                if let error {
                    Section { Text(error).foregroundStyle(Color.gwErrInk) }
                }
                if let updates { updatesSection(updates) }
                if web != nil { webSection }
                if decoy != nil { decoySection }
                if dns != nil { dnsSection }
                if log != nil, stats != nil { retentionSection }
                if log != nil { logSection }
                Section {
                    Button("Restart service…") { confirmRestart = true }
                } footer: {
                    Text("Users, API tokens, two-step sign-in and backups are managed in the web interface.")
                }
            }
            .groundBackground()
            .navigationTitle("Settings")
            .serverToolbar()
            .refreshable { await load() }
            .task { await load() }
            .alert("Restart to apply?", isPresented: $offerRestart) {
                Button("Later", role: .cancel) {}
                Button("Restart now") { Task { await restart() } }
            } message: {
                Text("The web interface uses the new settings after the service restarts. VPN connections stay up.")
            }
            .confirmationDialog("Restart the service?", isPresented: $confirmRestart, titleVisibility: .visible) {
                Button("Restart") { Task { await restart() } }
            } message: {
                Text("The web interface and API are gone for a few seconds. VPN connections stay up.")
            }
            .confirmationDialog("Delete older data?", isPresented: $confirmShrink, titleVisibility: .visible) {
                Button("Save and delete", role: .destructive) { Task { await saveRetention() } }
            } message: {
                Text("The new limits are lower: older log files and traffic history beyond them are deleted. This cannot be undone.")
            }
            .confirmationDialog("Turn on Decoy?", isPresented: $confirmDecoy, titleVisibility: .visible) {
                Button("Turn on", role: .destructive) { Task { await saveDecoy(enabled: true) } }
            } message: {
                Text("The web interface disappears right away and the server shows the decoy page instead. Turn it off here to get it back.")
            }
            .confirmationDialog("Remove this server?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
                Button("Remove \(session.current?.name ?? "server")", role: .destructive) {
                    if let id = session.current?.id { session.remove(id) }
                }
            } message: {
                Text("The token is removed from this iPhone. Revoke it in the web interface too.")
            }
        }
    }

    @ViewBuilder private var deviceSection: some View {
        Section {
            HStack {
                Lockup(size: 40)
                Spacer()
            }
            .padding(.vertical, 4)
            if let s = session.current {
                LabeledContent("Name") {
                    TextField("Name", text: $serverName)
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                        .onChange(of: serverName) { session.rename(s.id, to: serverName) }
                        .onChange(of: s.name) { serverName = s.name }
                        .onAppear { serverName = s.name }
                        .accessibilityIdentifier("serverName")
                }
            }
            LabeledContent("Address", value: session.pairing?.base ?? "–")
            if let me = session.me {
                LabeledContent("Signed in as", value: "\(me.name) · \(me.scope == "ro" ? "read only" : "full access")")
                LabeledContent("Server version", value: me.version)
            }
            if let fp = session.pairing?.fingerprint, !fp.isEmpty {
                KV(key: "Pinned certificate (SHA-256)", value: fp, mono: true)
            }
            Button("Remove this server…", role: .destructive) { confirmDisconnect = true }
        } header: {
            Text("This server")
        } footer: {
            Text("Removing deletes the token from this iPhone. Revoke it in the web interface too.")
        }
        Section {
            Button { session.showServers = true } label: {
                LabeledContent("Servers", value: "\(session.servers.count)")
            }
            .foregroundStyle(Color.gwText)
            LabeledContent("App version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–")
        } header: {
            Text("This iPhone")
        }
    }

    private var webSection: some View {
        let w = Binding(get: { web! }, set: { web = $0 })
        let opt = { (kp: WritableKeyPath<TLSSettings, String?>) in
            Binding<String>(get: { web!.tls[keyPath: kp] ?? "" }, set: { web!.tls[keyPath: kp] = $0 })
        }
        return Section {
            LabeledContent("Listen address") {
                TextField(":443", text: w.listen).font(.mono(.body)).multilineTextAlignment(.trailing)
            }
            LabeledContent("HTTP listen address") {
                TextField("off", text: w.httpListen).font(.mono(.body)).multilineTextAlignment(.trailing)
            }
            Picker("HTTPS", selection: w.tls.mode) {
                Text("Let's Encrypt").tag("acme")
                Text("Self-signed").tag("selfsigned")
                Text("Certificate files").tag("files")
                Text("Off (reverse proxy)").tag("off")
            }
            if web!.tls.mode == "acme" {
                TextField("Domain", text: opt(\.domain)).font(.mono(.body))
                TextField("Email for Let's Encrypt (optional)", text: opt(\.email)).keyboardType(.emailAddress)
                Toggle("Use the staging CA", isOn: Binding(get: { web!.tls.staging ?? false }, set: { web!.tls.staging = $0 }))
            }
            if web!.tls.mode == "files" {
                TextField("Certificate file", text: opt(\.certFile)).font(.mono(.footnote))
                TextField("Key file", text: opt(\.keyFile)).font(.mono(.footnote))
            }
            Picker("Session length", selection: w.sessionHours) {
                Text("1 hour").tag(1)
                Text("12 hours").tag(12)
                Text("1 day").tag(24)
                Text("7 days").tag(168)
            }
            Button("Save web settings") { Task { await saveWeb() } }
                .disabled(busy || web == settings?.web)
        } header: {
            Text("Web interface")
        } footer: {
            Text("Takes effect after the service restarts.")
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private var decoySection: some View {
        Section {
            Toggle("Decoy", isOn: Binding(get: { decoy!.enabled }, set: { on in
                if on {
                    confirmDecoy = true
                } else {
                    Task { await saveDecoy(enabled: false) }
                }
            }))
            .disabled(busy)
            Picker("Decoy page", selection: Binding(get: { decoy!.page }, set: { page in
                Task { await saveDecoy(page: page) }
            })) {
                Text("nginx").tag("nginx")
                Text("Apache").tag("apache")
                Text("Coming soon").tag("soon")
                Text("Blank page").tag("blank")
                Text("Forbidden").tag("forbidden")
                Text("Private server").tag("private")
            }
            .disabled(busy)
        } header: {
            Text("Decoy")
        } footer: {
            Text("Shows an ordinary web server page instead of the web interface. This app and setup links keep working. Applies immediately.")
        }
    }

    /// The DNS form: system resolver, or servers of its own with an
    /// optional fallback.
    struct DNSDraft: Equatable {
        var custom: Bool
        var servers: String
        var fallback: Bool

        init(_ d: DNSSettings) {
            custom = !d.servers.isEmpty
            servers = (d.servers.isEmpty ? quad9DNS : d.servers).joined(separator: ", ")
            fallback = d.fallback
        }

        var list: [String] {
            custom ? servers.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init) : []
        }

        var body: [String: Any] { ["servers": list, "fallback": fallback] }
    }

    private var dnsSection: some View {
        let d = Binding(get: { dns! }, set: { dns = $0; dnsResult = nil; dnsError = nil })
        let system = settings?.dns?.system ?? []
        let saved = settings?.dns
        let unchanged = saved.map { $0.servers == dns!.list && $0.fallback == dns!.fallback } ?? true
        return Section {
            Picker("Lookups", selection: d.custom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("System resolver")
                    Text("From /etc/resolv.conf: " + (system.isEmpty ? "none found" : system.joined(separator: ", ")))
                        .font(.caption).foregroundStyle(Color.gwText2)
                }
                .tag(false)
                VStack(alignment: .leading, spacing: 2) {
                    Text("These servers")
                    Text("Ignores the system settings for GHOSTWIRE only").font(.caption).foregroundStyle(Color.gwText2)
                }
                .tag(true)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if dns!.custom {
                Picker("DNS provider", selection: Binding(
                    get: { dns!.list == quad9DNS ? "quad9" : "custom" },
                    set: { d.wrappedValue.servers = $0 == "quad9" ? quad9DNS.joined(separator: ", ") : "" }
                )) {
                    Text("Quad9").tag("quad9")
                    Text("Custom").tag("custom")
                }
                LabeledContent("DNS servers") {
                    TextField("9.9.9.9, 149.112.112.112", text: d.servers)
                        .font(.mono(.footnote))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.numbersAndPunctuation)
                }
                Toggle(isOn: d.fallback) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fall back to the system resolver")
                        Text("Only when none of these servers answers. Off: lookups fail instead")
                            .font(.caption).foregroundStyle(Color.gwText2)
                    }
                }
            }
            if let dnsResult {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Color.gwGood).frame(width: 8, height: 8)
                    Text(dnsResult).font(.footnote)
                }
            }
            if let dnsError {
                Text(dnsError).font(.footnote).foregroundStyle(Color.gwErrInk)
            }
            Button(testingDNS ? "Looking up api.github.com…" : "Test") { Task { await testDNS() } }
                .disabled(testingDNS)
            Button("Save DNS") { Task { await saveDNS() } }
                .disabled(busy || unchanged)
        } header: {
            Text("DNS")
        } footer: {
            Text("How GHOSTWIRE looks up names: update check, geo databases, Let's Encrypt and public IP detection. Other programs on the server and the DNS in device configs (set under Server) are not affected. Applies immediately.")
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private func updatesSection(_ st: UpdateStatus) -> some View {
        Section {
            LabeledContent("Running", value: "v" + String(st.current.trimmingPrefix("v")))
            if let rel = st.latest {
                LabeledContent("Latest release") {
                    Text(rel.version).foregroundStyle(st.available ? Color.gwDown : Color.gwText2)
                        .fontWeight(st.available ? .semibold : .regular)
                }
            }
            LabeledContent("This server", value: st.arch.isEmpty ? "No release file for this platform" : "Linux · " + st.arch)
            if st.enabled, let e = st.error, !e.isEmpty {
                Text("The last check failed: \(e)." + (st.lastOk.map { " Last worked " + ago($0) + "." } ?? ""))
                    .font(.footnote)
                    .foregroundStyle(Color.gwErrInk)
            }
            if let rel = st.latest {
                if st.available {
                    releaseNotes(rel)
                    if let cmds = updateCommands(st) {
                        updateCommandsView(cmds)
                        Button(copiedCommands ? "Copied" : "Copy commands") {
                            UIPasteboard.general.string = cmds
                            copiedCommands = true
                        }
                    } else {
                        HStack(spacing: 4) {
                            Text("No release file is built for this platform.")
                            if let url = URL(string: rel.url) { Link("See the release", destination: url).underline() }
                        }
                        .font(.footnote)
                    }
                } else {
                    HStack(spacing: 8) {
                        Circle().fill(Color.gwGood).frame(width: 8, height: 8)
                        Text("GHOSTWIRE is up to date.")
                    }
                }
            }
            Toggle(isOn: Binding(get: { st.enabled }, set: { on in Task { await saveUpdateCheck(on) } })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Check for updates once a day")
                    Text("Asks github.com for the latest release. Nothing about this server is sent.")
                        .font(.caption).foregroundStyle(Color.gwText2)
                }
            }
            .disabled(checking)
            if st.enabled {
                Button(checking ? "Checking…" : "Check now") { Task { await checkNow() } }
                    .disabled(checking)
            }
        } header: {
            HStack {
                Text("Updates")
                Spacer()
                if st.enabled { Text(st.checked.map { "Last checked " + ago($0) } ?? "Not checked yet") }
            }
        }
    }

    private func releaseNotes(_ rel: Release) -> some View {
        let notes = ReleaseSummary(rel.notes)
        return VStack(alignment: .leading, spacing: 8) {
            Text("What's new in \(rel.version)").font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                Text("Released " + fmtDate(rel.published))
                if let url = URL(string: rel.url) { Link("Full notes on GitHub", destination: url).underline() }
            }
            .font(.caption)
            .foregroundStyle(Color.gwText2)
            if notes.summary.range(of: "security", options: .caseInsensitive) != nil {
                Notice(text: "Includes security fixes.")
            }
            if !notes.summary.isEmpty { Text(inlineMarkdown(notes.summary)).font(.footnote) }
            ForEach(Array(notes.items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•")
                    Text(inlineMarkdown(item))
                }
                .font(.footnote)
            }
        }
        .padding(.vertical, 4)
    }

    private func updateCommandsView(_ cmds: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Update this server").font(.subheadline.weight(.semibold))
            Text("Run on the server. VPN connections stay up.").font(.caption).foregroundStyle(Color.gwText2)
            Text(cmds)
                .font(.mono(.caption2))
                .foregroundStyle(Color(hex: 0xE6E6E1))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(hex: 0x16171A), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.vertical, 4)
    }

    /// The commands the web interface shows for updating this server.
    private func updateCommands(_ st: UpdateStatus) -> String? {
        guard st.available, let file = st.file, let fileUrl = st.fileUrl, let sumsUrl = st.sumsUrl else { return nil }
        return ["curl -fLO " + fileUrl, "curl -fLO " + sumsUrl, "sha256sum -c --ignore-missing SHA256SUMS",
                "chmod +x " + file, "sudo ./" + file + " update"].joined(separator: "\n")
    }

    private var retentionSection: some View {
        let l = Binding(get: { log! }, set: { log = $0 })
        let s = Binding(get: { stats! }, set: { stats = $0 })
        return Section {
            Stepper("Log file size: \(log!.maxSizeMB) MB", value: l.maxSizeMB, in: 1...1000)
            Stepper("Old log files kept: \(log!.maxFiles)", value: l.maxFiles, in: 1...100)
            Picker("Hourly traffic history", selection: s.hourlyHours) {
                ForEach(options(Self.hourly, current: stats!.hourlyHours, unit: "hours"), id: \.0) { Text($0.1).tag($0.0) }
            }
            Picker("Daily traffic history", selection: s.dailyDays) {
                ForEach(options(Self.daily, current: stats!.dailyDays, unit: "days"), id: \.0) { Text($0.1).tag($0.0) }
            }
            Toggle(isOn: Binding(get: { stats!.geoip ?? true }, set: { stats!.geoip = $0 })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show country and network")
                    Text(geoStatusText).font(.caption).foregroundStyle(Color.gwText2)
                }
            }
            Button("Save retention") {
                guard let old = settings, let log, let stats else { return }
                if log.maxFiles < old.log.maxFiles || stats.hourlyHours < old.stats.hourlyHours || stats.dailyDays < old.stats.dailyDays {
                    confirmShrink = true
                } else {
                    Task { await saveRetention() }
                }
            }
            .disabled(busy || (log == settings?.log && stats == settings?.stats))
        } header: {
            Text("Data retention")
        } footer: {
            Text("The log uses up to \(log!.maxSizeMB * (log!.maxFiles + 1)) MB on disk. Connection history is kept as long as the daily traffic history; all-time totals are always kept. Country and network come from the free DB-IP Lite databases, downloaded monthly and looked up on the server only. Applies immediately.")
        }
    }

    private var logSection: some View {
        Section {
            Picker("Log level", selection: Binding(get: { log!.level }, set: { level in
                log!.level = level
                Task { await saveLevel(level) }
            })) {
                ForEach(["debug", "info", "warn", "error"], id: \.self) { Text($0).tag($0) }
            }
            NavigationLink("View log") { LogView() }
        } header: {
            Text("Log")
        } footer: {
            Text(settings?.logPath ?? "")
        }
    }

    private var geoStatusText: String {
        guard let updated = settings?.geo?.updated else { return "Database not downloaded yet" }
        return "Database from \(fmtDate(updated))"
    }

    private func options(_ presets: [(Int, String)], current: Int, unit: String) -> [(Int, String)] {
        presets.contains { $0.0 == current } ? presets : (presets + [(current, "\(current) \(unit)")]).sorted { $0.0 < $1.0 }
    }

    private func load() async {
        guard let api = session.api else { return }
        do {
            let s: AppSettings = try await api.get("/settings")
            settings = s
            web = s.web
            log = s.log
            stats = s.stats
            decoy = s.decoy
            dns = s.dns.map(DNSDraft.init)
            dnsResult = nil
            dnsError = nil
            updates = s.updates
            error = nil
        } catch {
            self.error = session.message(for: error)
        }
    }

    private func patch(_ body: [String: Any?]) async throws -> SettingsResult {
        guard let api = session.api else { throw APIError.unauthorized(nil) }
        return try await api.send("PATCH", "/settings", body)
    }

    private func encoded<T: Encodable>(_ v: T) -> Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(v))) ?? NSNull()
    }

    private func saveWeb() async {
        guard let web else { return }
        busy = true
        defer { busy = false }
        do {
            let r = try await patch(["web": encoded(web)])
            settings?.web = web
            error = nil
            if r.restartRequired { offerRestart = true }
        } catch {
            self.error = session.message(for: error)
        }
    }

    private func saveRetention() async {
        guard let log, let stats else { return }
        busy = true
        defer { busy = false }
        do {
            _ = try await patch(["log": encoded(log), "stats": encoded(stats)])
            settings?.log = log
            settings?.stats = stats
            error = nil
        } catch {
            self.error = session.message(for: error)
        }
    }

    private func saveLevel(_ level: String) async {
        guard var l = settings?.log else { return }
        l.level = level
        do {
            _ = try await patch(["log": encoded(l)])
            settings?.log.level = level
        } catch {
            self.error = session.message(for: error)
        }
    }

    private func saveDecoy(enabled: Bool? = nil, page: String? = nil) async {
        guard var d = decoy else { return }
        if let enabled { d.enabled = enabled }
        if let page { d.page = page }
        busy = true
        defer { busy = false }
        do {
            _ = try await patch(["decoy": encoded(d)])
            decoy = d
            settings?.decoy = d
            error = nil
        } catch {
            self.error = session.message(for: error)
        }
    }

    private func testDNS() async {
        guard let api = session.api, let dns else { return }
        testingDNS = true
        defer { testingDNS = false }
        dnsResult = nil
        dnsError = nil
        do {
            let r: DNSTestResult = try await api.send("POST", "/dns/test", dns.body.mapValues { $0 as Any? })
            dnsResult = "\(r.name) → \(r.answer) in \(r.ms) ms, answered by \(r.server)"
        } catch {
            dnsError = session.message(for: error)
        }
    }

    private func saveDNS() async {
        guard let dns else { return }
        busy = true
        defer { busy = false }
        dnsError = nil
        do {
            _ = try await patch(["dns": dns.body])
            settings?.dns?.servers = dns.list
            settings?.dns?.fallback = dns.fallback
        } catch {
            dnsError = session.message(for: error)
        }
    }

    private func checkNow() async {
        guard let api = session.api else { return }
        checking = true
        defer { checking = false }
        copiedCommands = false
        do {
            updates = try await api.send("POST", "/updates/check")
            // The dashboard's update notice comes from /auth/me.
            if let m: Me = try? await api.get("/auth/me") { session.me = m }
        } catch {
            self.error = session.message(for: error)
        }
    }

    private func saveUpdateCheck(_ on: Bool) async {
        guard let api = session.api else { return }
        do {
            _ = try await patch(["updates": ["check": on]])
            if on {
                await checkNow()
            } else {
                let s: AppSettings = try await api.get("/settings")
                updates = s.updates
                if let m: Me = try? await api.get("/auth/me") { session.me = m }
            }
        } catch {
            self.error = session.message(for: error)
        }
    }

    private func restart() async {
        guard let api = session.api else { return }
        _ = try? await api.data("POST", "/restart")
        session.alert = "Restarting. The app reconnects in a few seconds."
    }
}

struct LogView: View {
    @Environment(AppSession.self) private var session
    @State private var show = ""  // "" (by level) | "audit" (changes) | "dns" (DNS queries)
    @State private var level = "all"
    @State private var lines: [String] = []
    @State private var error: String?
    @State private var sharing = false
    @State private var logFile: URL?

    var body: some View {
        List {
            Section {
                Picker("Show", selection: $show) {
                    Text("All").tag("")
                    Text("Changes only").tag("audit")
                    Text("DNS").tag("dns")
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                if show.isEmpty {
                    Picker("Level", selection: $level) {
                        Text("All levels").tag("all")
                        Text("Info").tag("info")
                        Text("Warn").tag("warn")
                        Text("Error").tag("error")
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(Color.gwErrInk) }
            }
            Section {
                if lines.isEmpty && error == nil {
                    Text(emptyText).foregroundStyle(Color.gwText2)
                }
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.mono(.caption2))
                        .textSelection(.enabled)
                }
            } footer: {
                Text("Newest first, up to 500 entries. Share the log file for all of it.")
            }
        }
        .groundBackground()
        .navigationTitle("Log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await shareFile() } } label: {
                    if sharing { ProgressView() } else { Label("Share log file", systemImage: "square.and.arrow.up") }
                }
                .disabled(sharing)
            }
        }
        .sheet(isPresented: Binding(get: { logFile != nil }, set: { if !$0 { logFile = nil } })) {
            if let logFile {
                ActivitySheet(items: [logFile])
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
        }
        .onChange(of: show) { Task { await load() } }
        .onChange(of: level) { Task { await load() } }
        .refreshable { await load() }
        .task { await load() }
    }

    private var emptyText: String {
        switch show {
        case "audit": "No changes in the log yet."
        case "dns": "No DNS queries in the log yet."
        default: "No entries at this level."
        }
    }

    private func load() async {
        guard let api = session.api else { return }
        // Changes and DNS queries are shown at every level, like the web interface.
        let query = show.isEmpty ? "level=\(level)" : "level=all&\(show)=1"
        do {
            let data = try await api.data("GET", "/logs?limit=500&" + query)
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let recs = obj?["lines"] as? [[String: Any]] ?? []
            lines = recs.map(formatLogLine)
            error = nil
        } catch {
            self.error = session.message(for: error)
        }
    }

    /// Downloads the current log file and opens the share sheet with it.
    private func shareFile() async {
        guard let api = session.api else { return }
        sharing = true
        defer { sharing = false }
        do {
            let data = try await api.data("GET", "/logs/download")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("GHOSTWIRE.jsonl")
            try data.write(to: url, options: .atomic)
            logFile = url
        } catch {
            session.alert = session.message(for: error)
        }
    }
}

/// The system share sheet, for files the app downloads first.
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
