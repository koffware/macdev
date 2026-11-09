import MacDevCore
import SwiftUI

struct ServicesView: View {
    @ObservedObject var store: SiteStore
    let selection: String?
    /// Opens a service's page from the overview, as if chosen in the sidebar.
    let select: (String) -> Void
    @State private var stopping: Service?

    var body: some View {
        Group {
            if selection == "all" {
                overview
            } else if let service = store.services.first(where: { $0.id == selection }) {
                ServiceDetailView(store: store, service: service) { stopping = service }.id(service.id)
            } else {
                VStack {
                    if let error = store.servicesError {
                        Text(error).foregroundStyle(.red).textSelection(.enabled)
                    } else if store.isLoadingServices {
                        ProgressView("Reading service status…")
                    } else {
                        ContentUnavailableView(
                            "Select a service", systemImage: "server.rack",
                            description: Text("Choose a service from the sidebar to see its status and controls."))
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
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
            Text(stopping.map(stopMessage) ?? "")
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let error = store.servicesError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if store.isLoadingServices && store.services.isEmpty { ProgressView("Reading service status…") }
            List(store.services) { service in serviceRow(service) }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .overlay {
                    if store.services.isEmpty && !store.isLoadingServices && store.servicesError == nil {
                        ContentUnavailableView(
                            "No Homebrew services", systemImage: "server.rack",
                            description: Text("Install nginx or PHP with Homebrew, then refresh."))
                    }
                }
            Text(
                "Start registers a service to launch at login. Stop removes that registration. Stopping PHP or nginx interrupts the sites that use it."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: 1000, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func serviceRow(_ service: Service) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "server.rack")
                .font(.title2).foregroundStyle(.secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(service.name).fontWeight(.semibold)
                HStack(spacing: 10) {
                    ServiceStatusLabel(service: service)
                    if let usage = store.usageSummary(of: service) {
                        Text(usage).foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
            }
            Spacer()
            ServiceControls(store: store, service: service, showDetails: { select(service.id) }) {
                stopping = service
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { select(service.id) }
    }

    /// Names the sites that stop working, so the cost of stopping is clear before confirming.
    private func stopMessage(_ service: Service) -> String {
        guard let dependents = store.sites(dependingOn: service), !dependents.isEmpty else {
            return "Applications using this service may become unavailable until it is started again."
        }
        let shown = dependents.prefix(4).map(\.domain)
        let names =
            shown.joined(separator: ", ")
            + (dependents.count > shown.count ? " and \(dependents.count - shown.count) more" : "")
        if service.name == "nginx" {
            return "Every site stops responding until nginx is started again: \(names)."
        }
        let verb = dependents.count == 1 ? "returns" : "return"
        return "\(names) \(verb) 502 Bad Gateway until \(service.name) is started again."
    }
}
