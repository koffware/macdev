import MacDevCore
import SwiftUI

struct ServicesView: View {
    @ObservedObject var store: SiteStore
    var selection: String? = "all"

    private var visibleServices: [Service] {
        selection == "all" ? store.services : store.services.filter { $0.id == selection }
    }
    @State private var stopping: Service?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let error = store.servicesError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if store.isLoadingServices && store.services.isEmpty { ProgressView("Reading service status…") }
            if selection == "all" {
                List(visibleServices) { service in serviceRow(service) }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
            } else if let service = visibleServices.first {
                Text(service.name).font(.title2.weight(.semibold))
                WorkspacePanel { serviceRow(service).padding(16) }
                Spacer(minLength: 0)
            } else if !store.isLoadingServices && store.servicesError == nil {
                ContentUnavailableView(
                    "Select a service", systemImage: "server.rack",
                    description: Text("Choose a service from the sidebar to see its status and controls."))
            }
            Text(
                "Start registers a service to launch at login. Stop removes that registration. Stopping PHP or nginx interrupts the sites that use it."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 1000, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { await store.loadServices() }
        .confirmationDialog(
            "Stop \(stopping?.name ?? "service")?",
            isPresented: Binding(
                get: { stopping != nil }, set: { if !$0 { stopping = nil } }
            ), titleVisibility: .visible
        ) {
            if let service = stopping {
                Button("Stop \(service.name)", role: .destructive) {
                    Task { await store.controlService(service, action: "stop") }
                }
            }
        } message: {
            Text("Applications using this service may become unavailable until it is started again.")
        }
    }

    private func serviceRow(_ service: Service) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.title2).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(service.name).fontWeight(.semibold)
                Label(
                    service.status + (service.exitCode.map { " · Exit \($0)" } ?? ""),
                    systemImage: service.isRunning ? "checkmark.circle.fill" : "circle"
                )
                .font(.caption).foregroundStyle(service.isRunning ? .green : .secondary)
            }
            Spacer()
            Button(service.isRunning ? "Restart" : "Start") {
                Task { await store.controlService(service, action: service.isRunning ? "restart" : "start") }
            }
            Menu {
                Button("Restart") { Task { await store.controlService(service, action: "restart") } }
                if service.name == "nginx" {
                    Button("Reload") { Task { await store.controlService(service, action: "reload") } }
                        .disabled(!service.isRunning)
                }
                Divider()
                Button("Stop…", role: .destructive) { stopping = service }
                    .disabled(service.status == "none" || service.status == "stopped")
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).fixedSize().frame(width: 24)
            .accessibilityLabel("Actions for \(service.name)")
        }
        .padding(.vertical, 6)
        .disabled(store.isBusy || store.isLoadingServices)
    }
}
