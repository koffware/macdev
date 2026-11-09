import MacDevCore
import SwiftUI

/// One Homebrew service: what it is doing, which sites depend on it, and why it failed.
struct ServiceDetailView: View {
    @ObservedObject var store: SiteStore
    let service: Service
    let onStop: () -> Void
    @State private var details: ServiceDetails?
    @State private var loadError: String?
    @State private var check: ServiceCheck?
    @State private var checkError: String?
    @State private var isChecking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 18) {
                        heading
                        Spacer(minLength: 12)
                        ServiceControls(store: store, service: service, onStop: onStop)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        heading
                        ServiceControls(store: store, service: service, onStop: onStop)
                    }
                }
                if let loadError {
                    Text(loadError).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }
                if service.hasError || details?.explanation != nil { problem }
                Divider()
                section("Process") { process }
                if let dependents = store.sites(dependingOn: service) {
                    section("Sites") { sites(dependents) }
                }
                section("Launch") { launch }
                section("Logs") { logs }
            }
            .padding(20)
            .frame(maxWidth: 1060, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Homebrew status is re-read after every action and refresh; follow it.
        .task(id: store.servicesRevision) { await load() }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(service.name).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 14) {
                ServiceStatusLabel(service: service)
                if service.isRunning, let uptime = details?.uptimeSummary {
                    Label("Up \(uptime)", systemImage: "clock").foregroundStyle(.secondary)
                }
                if let usage = store.usageSummary(of: service) {
                    Label(usage, systemImage: "globe").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
        }
    }

    // MARK: Problem

    private var problem: some View {
        let isError = service.hasError
        let color: Color = isError ? .red : .orange
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isError ? "exclamationmark.octagon.fill" : "lock.fill").foregroundStyle(color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(problemTitle).fontWeight(.medium)
                    Text(
                        details?.explanation
                            ?? "Homebrew could not keep \(service.name) running. The configuration check and logs below may show why."
                    )
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let command = details?.terminalCommand {
                HStack(spacing: 10) {
                    Text(command)
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    Button("Copy") { store.copyToPasteboard(command, label: "Terminal command") }
                        .help("Copy this command, then run it in Terminal")
                }
                .padding(.leading, 26)
                Text("Run this in Terminal. MacDev never asks for administrator rights.")
                    .font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private var problemTitle: String {
        if service.hasError {
            return service.exitCode.map { "\(service.name) stopped with exit code \($0)" }
                ?? "\(service.name) reported an error"
        }
        return "Controlled from Terminal"
    }

    // MARK: Process

    @ViewBuilder private var process: some View {
        if !service.isRunning {
            DetailRow("Process") {
                Text(service.hasError ? "Not running · see the problem above" : "Not running")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        } else if let details {
            DetailRow("PID") {
                Text(details.pid.map(String.init) ?? "Unknown").monospacedDigit().textSelection(.enabled)
                Spacer(minLength: 0)
            }
            Divider().padding(.horizontal, 16)
            DetailRow("Memory") {
                Text(details.memorySummary ?? "Unknown")
                Spacer(minLength: 0)
                ContextHelp(
                    "Resident memory of the main process and every process it started, such as nginx or PHP-FPM workers."
                )
            }
            Divider().padding(.horizontal, 16)
            DetailRow("Listening on") {
                Text(details.portSummary ?? (details.ports == nil ? "Could not be read" : "No open ports"))
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .foregroundStyle(details.portSummary == nil ? .secondary : .primary)
                Spacer(minLength: 0)
                ContextHelp(
                    "* accepts connections from other devices on your network. localhost accepts connections from this Mac only. Ports of services that run as root are not visible."
                )
            }
        } else if loadError == nil {
            DetailRow("Process") {
                ProgressView().controlSize(.small)
                Spacer(minLength: 0)
            }
        } else {
            DetailRow("Process") {
                Text("Unavailable").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Sites

    @ViewBuilder private func sites(_ dependents: [Site]) -> some View {
        if dependents.isEmpty {
            DetailRow("Sites") {
                Text(
                    service.name == "nginx"
                        ? "No sites yet."
                        : "\(store.usageSummary(of: service) ?? "No sites use it"). Stop it to free its memory."
                )
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        } else {
            ForEach(Array(dependents.enumerated()), id: \.element.id) { index, site in
                if index > 0 { Divider().padding(.horizontal, 16) }
                Button {
                    store.showSite(site)
                } label: {
                    HStack(spacing: 10) {
                        if let health = store.health(of: site) { HealthDot(health: health).help(health.message) }
                        Text(site.domain)
                        Text(site.summary).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(site.domain)")
            }
        }
    }

    // MARK: Launch

    @ViewBuilder private var launch: some View {
        if let details {
            DetailRow("Command") {
                PathText(value: details.command ?? "Unknown")
                Spacer(minLength: 0)
            }
            if let plist = details.plist {
                Divider().padding(.horizontal, 16)
                DetailRow(details.runsAsRoot ? "Launch daemon" : "Launch agent") {
                    PathText(value: plist)
                    Spacer(minLength: 0)
                    Button("Show in Finder") { store.revealFile(plist) }
                }
            }
            if let user = details.user {
                Divider().padding(.horizontal, 16)
                DetailRow("Runs as") {
                    Text(user).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
            }
            if details.canCheck {
                Divider().padding(.horizontal, 16)
                configurationCheck
            }
        } else {
            DetailRow("Command") {
                if loadError == nil { ProgressView().controlSize(.small) } else { Text("Unavailable") }
                Spacer(minLength: 0)
            }
        }
    }

    private var configurationCheck: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                Text("Configuration").foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
                if isChecking {
                    ProgressView().controlSize(.small)
                } else if let check {
                    Label(
                        check.ok ? "Test passed" : "Test failed",
                        systemImage: check.ok ? "checkmark.circle.fill" : "xmark.octagon.fill"
                    )
                    .foregroundStyle(check.ok ? Color.green : Color.red)
                    .help(check.command)
                } else {
                    Text(checkError ?? "Not checked").foregroundStyle(checkError == nil ? .secondary : Color.red)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                Button(check == nil ? "Check" : "Check Again") { Task { await runCheck() } }
                    .disabled(isChecking)
                    .help("Run \(service.name)’s own configuration test. Nothing is changed or restarted.")
            }
            .frame(minHeight: 22)
            if let check, !check.ok, !check.output.isEmpty {
                ScrollView([.vertical, .horizontal]) {
                    Text(check.output)
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(maxHeight: 180)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            }
        }
        .padding(16)
    }

    // MARK: Logs

    @ViewBuilder private var logs: some View {
        if let details, !details.logs.isEmpty {
            ForEach(Array(details.logs.enumerated()), id: \.element.id) { index, log in
                if index > 0 { Divider().padding(.horizontal, 16) }
                LogFileRow(
                    title: log.title, path: log.path, exists: log.exists, size: log.size,
                    modified: log.modifiedDate, open: { store.openFile(log.path) },
                    read: { await store.readServiceLog(service, kind: log.kind) })
            }
        } else {
            DetailRow("Logs") {
                if details == nil && loadError == nil {
                    ProgressView().controlSize(.small)
                } else {
                    Text(details == nil ? "Unavailable" : "Homebrew records no log file for this service.")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            WorkspacePanel { content() }
        }
    }

    private func load() async {
        switch await store.serviceDetails(service) {
        case .success(let value):
            details = value
            loadError = nil
            // A failed service most often has a configuration problem; look for it right away.
            if service.hasError && value.canCheck && check == nil && checkError == nil { await runCheck() }
        case .failure(let error):
            loadError = error.localizedDescription
        }
    }

    private func runCheck() async {
        isChecking = true
        defer { isChecking = false }
        switch await store.checkService(service) {
        case .success(let value):
            check = value
            checkError = nil
        case .failure(let error):
            check = nil
            checkError = error.localizedDescription
        }
    }
}

/// "Running", "Error · Exit code 2", with a matching symbol and color.
struct ServiceStatusLabel: View {
    let service: Service

    var body: some View {
        Label(
            service.statusTitle + (service.exitCode.map { $0 == 0 ? "" : " · Exit code \($0)" } ?? ""),
            systemImage: service.isRunning
                ? "checkmark.circle.fill" : (service.hasError ? "exclamationmark.circle.fill" : "circle")
        )
        .foregroundStyle(service.isRunning ? Color.green : (service.hasError ? Color.red : Color.secondary))
        .help("Homebrew status: \(service.status)")
    }
}

/// Start or restart, plus reload and stop in a menu.
struct ServiceControls: View {
    @ObservedObject var store: SiteStore
    let service: Service
    var showDetails: (() -> Void)?
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(service.isRunning ? "Restart" : "Start") {
                Task { await store.controlService(service, action: service.isRunning ? "restart" : "start") }
            }
            .help(service.isRunning ? "Restart \(service.name)" : "Start \(service.name) and launch it at login")
            Menu {
                if let showDetails {
                    Button("Show Details", action: showDetails)
                    Divider()
                }
                if service.name == "nginx" {
                    Button("Reload Configuration") { Task { await store.controlService(service, action: "reload") } }
                        .disabled(!service.isRunning)
                    Divider()
                }
                Button("Stop…", role: .destructive, action: onStop)
                    .disabled(!service.isRegistered)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 24)
            .help("More actions").accessibilityLabel("Actions for \(service.name)")
        }
        .disabled(store.isBusy || store.isLoadingServices)
    }
}
