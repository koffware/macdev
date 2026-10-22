import MacDevCore
import SwiftUI

struct ServicesView: View {
    @ObservedObject var store: SiteStore
    @State private var stopping: Service?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Services").font(.largeTitle.weight(.semibold))
                    Text("Homebrew services for your account").foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await store.loadServices() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(store.isBusy || store.isLoadingServices)
            }
            if let error = store.servicesError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if store.isLoadingServices { ProgressView("Reading service status…") }
            List(store.services) { service in
                HStack(spacing: 14) {
                    Image(systemName: service.isRunning ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(service.isRunning ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(service.name).fontWeight(.medium)
                        Text(service.status + (service.exitCode.map { " · Exit \($0)" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Start") { Task { await store.controlService(service, action: "start") } }
                        .disabled(service.isRunning)
                    Button("Restart") { Task { await store.controlService(service, action: "restart") } }
                    if service.name == "nginx" {
                        Button("Reload") { Task { await store.controlService(service, action: "reload") } }
                            .disabled(!service.isRunning)
                    }
                    Button("Stop", role: .destructive) { stopping = service }
                        .disabled(service.status == "none" || service.status == "stopped")
                }
                .padding(.vertical, 8)
                .disabled(store.isBusy || store.isLoadingServices)
            }
            .listStyle(.inset)
            Text("Start registers a service to launch at login. Stop removes that registration. Stopping PHP or nginx interrupts the sites that use it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(26)
        .task { await store.loadServices() }
        .confirmationDialog("Stop \(stopping?.name ?? "service")?", isPresented: Binding(
            get: { stopping != nil }, set: { if !$0 { stopping = nil } }
        ), titleVisibility: .visible) {
            if let service = stopping {
                Button("Stop \(service.name)", role: .destructive) { Task { await store.controlService(service, action: "stop") } }
            }
        } message: { Text("Applications using this service may become unavailable until it is started again.") }
    }
}
