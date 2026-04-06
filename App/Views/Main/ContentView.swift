import SwiftUI

struct ContentView: View {
    @EnvironmentObject var errorLog: ErrorLog
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardView()
                .tag(0)
                .tabItem { Label("Dashboard", systemImage: "thermometer.medium") }

            SettingsView()
                .tag(1)
                .tabItem { Label("Settings", systemImage: "gear") }
        }
        .frame(minWidth: 700, minHeight: 500)
        .overlay(alignment: .top) {
            if let toast = errorLog.currentToast {
                ErrorToastView(entry: toast) {
                    errorLog.dismissToast()
                }
                .padding(.top, 8)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: errorLog.currentToast?.id)
    }
}
