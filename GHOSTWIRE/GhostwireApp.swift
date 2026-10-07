import SwiftUI

@main
struct GhostwireApp: App {
    @State private var session = AppSession()

    init() { BrandFont.register() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
                .tint(Color.gwAccent)
        }
    }
}

struct RootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        @Bindable var session = session
        Group {
            if let s = session.current {
                if session.revoked.contains(s.id) {
                    RevokedView(server: s)
                } else {
                    // A new identity per server resets every tab's state,
                    // polling and streams when switching.
                    MainTabView().id(s.id)
                }
            } else {
                PairingView()
            }
        }
        .sheet(isPresented: $session.showServers) { ServersView() }
        .alert("GHOSTWIRE", isPresented: Binding(get: { session.alert != nil }, set: { if !$0 { session.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.alert ?? "")
        }
    }
}

struct MainTabView: View {
    enum Tab: String { case dashboard, live, peers, server, settings }

    @Environment(AppSession.self) private var session

    var body: some View {
        @Bindable var session = session
        TabView(selection: $session.tab) {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "square.grid.2x2") }
                .tag(Tab.dashboard)
            LiveView()
                .tabItem { Label("Live", systemImage: "waveform.path.ecg") }
                .tag(Tab.live)
            PeersView()
                .tabItem { Label("Peers", systemImage: "person.2") }
                .tag(Tab.peers)
            ServerView()
                .tabItem { Label("Server", systemImage: "server.rack") }
                .tag(Tab.server)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(Tab.settings)
        }
        .task {
            await session.loadMe()
            await session.probeAll()
        }
    }
}
