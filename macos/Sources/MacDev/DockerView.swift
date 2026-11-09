import MacDevCore
import SwiftUI

/// Docker sidebar selections: the container overview, images, a Compose project, or one container.
enum DockerSelection {
    static let overview = "overview"
    static let images = "images"
    static func project(_ name: String) -> String { "project:\(name)" }
    static func container(_ id: String) -> String { "container:\(id)" }
}

extension DockerContainer {
    var statusColor: Color {
        if hasError { return .red }
        switch state {
        case "running": return currentHealth == "starting" ? .orange : .green
        case "paused", "restarting": return .orange
        default: return .secondary
        }
    }

    /// A shell inside the container, for people to run in Terminal.
    var shellCommand: String { "docker exec -it \(name) sh" }
}

extension DockerProject {
    var statusColor: Color {
        if hasError { return .red }
        if runningCount == 0 { return .secondary }
        return runningCount == containers.count ? .green : .orange
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
    }
}

// MARK: - Sidebar

struct DockerSidebar: View {
    @ObservedObject var store: SiteStore
    @Binding var selection: String?
    @State private var collapsed: Set<String> = []
    @State private var search = ""

    var body: some View {
        List(selection: $selection) {
            Section("Docker") {
                Label {
                    Text("Containers")
                } icon: {
                    Image(systemName: "shippingbox")
                }
                .badge(store.docker.map { $0.running ? $0.runningCount : 0 } ?? 0)
                .tag(DockerSelection.overview)
                Label("Images", systemImage: "square.stack.3d.up").tag(DockerSelection.images)
            }
            if let state = store.docker, state.running {
                let projects = state.projects.compactMap(filtered)
                if !projects.isEmpty {
                    Section("Compose Projects") {
                        ForEach(projects) { project in
                            DisclosureGroup(isExpanded: expansion(of: project)) {
                                ForEach(project.containers) { container in
                                    row(container, title: container.displayName)
                                }
                            } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(project.name)
                                        Text(project.summary).font(.caption)
                                            .foregroundStyle(project.hasError ? Color.red : Color.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "square.stack.3d.down.right")
                                }
                                .tag(DockerSelection.project(project.name))
                            }
                        }
                    }
                }
                let standalone = state.standaloneContainers.filter(matches)
                if !standalone.isEmpty {
                    Section("Containers") {
                        ForEach(standalone) { container in row(container, title: container.name) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar, prompt: "Search containers")
        .onChange(of: selection) { _, value in
            // Reveal a container chosen from a page inside its collapsed project.
            guard let id = value?.split(separator: ":", maxSplits: 1).last,
                value?.hasPrefix("container:") == true,
                let project = store.docker?.container(id: String(id))?.project
            else { return }
            collapsed.remove(project)
        }
    }

    private func row(_ container: DockerContainer, title: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(container.statusTitle).font(.caption).lineLimit(1)
                    .foregroundStyle(container.hasError ? Color.red : Color.secondary)
            }
        } icon: {
            StatusDot(color: container.statusColor)
        }
        .tag(DockerSelection.container(container.id))
        .help(container.name)
    }

    private func expansion(of project: DockerProject) -> Binding<Bool> {
        Binding(
            get: { !search.isEmpty || !collapsed.contains(project.name) },
            set: { isExpanded in
                if isExpanded { collapsed.remove(project.name) } else { collapsed.insert(project.name) }
            })
    }

    private func matches(_ container: DockerContainer) -> Bool {
        search.isEmpty
            || [container.name, container.service, container.image, container.project]
                .contains { $0?.localizedCaseInsensitiveContains(search) == true }
    }

    /// The project with only matching containers; all of them when its own name matches.
    private func filtered(_ project: DockerProject) -> DockerProject? {
        if search.isEmpty || project.name.localizedCaseInsensitiveContains(search) { return project }
        let containers = project.containers.filter(matches)
        return containers.isEmpty ? nil : DockerProject(name: project.name, containers: containers)
    }
}

// MARK: - Detail

/// A destructive Docker action waiting for confirmation.
enum DockerRemoval: Identifiable {
    case container(DockerContainer)
    case image(DockerImage)
    case dangling(count: Int, size: Int64)

    var id: String {
        switch self {
        case .container(let container): "container:\(container.id)"
        case .image(let image): "image:\(image.id)"
        case .dangling: "dangling"
        }
    }

    var title: String {
        switch self {
        case .container(let container): "Remove \(container.name)?"
        case .image(let image): "Remove \(image.title)?"
        case .dangling(let count, _): "Remove \(count) dangling \(count == 1 ? "image" : "images")?"
        }
    }

    var confirmTitle: String {
        switch self {
        case .container: "Remove Container"
        case .image: "Remove Image"
        case .dangling: "Remove Images"
        }
    }

    var message: String {
        switch self {
        case .container(let container):
            container.project == nil
                ? "The container and its changes outside volumes are deleted. Named volumes and bind-mounted folders are kept."
                : "The container is deleted; named volumes and folders are kept. Running `docker compose up` in the project folder creates it again."
        case .image(let image):
            "\(image.sizeSummary ?? "The image") is freed. Docker downloads or builds it again the next time it is needed."
        case .dangling(_, let size):
            "Untagged images that no container uses are deleted, freeing up to \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))."
        }
    }
}

struct DockerView: View {
    @ObservedObject var store: SiteStore
    let selection: String?
    let select: (String) -> Void
    @State private var removal: DockerRemoval?

    var body: some View {
        Group {
            if let state = store.docker {
                if !state.installed {
                    ContentUnavailableView(
                        "Docker is not installed", systemImage: "shippingbox",
                        description: Text("Install Docker Desktop, OrbStack, or the docker CLI, then refresh."))
                } else if !state.running {
                    DockerEngineStoppedView(store: store, state: state)
                } else {
                    content(state)
                }
            } else if let error = store.dockerError {
                ContentUnavailableView {
                    Label("Could not read Docker", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error).textSelection(.enabled)
                } actions: {
                    Button("Try Again") { Task { await store.loadDocker(force: true) } }
                }
            } else {
                ProgressView("Reading containers and images…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await store.loadDocker() }
        .confirmationDialog(
            removal?.title ?? "", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }),
            titleVisibility: .visible, presenting: removal
        ) { pending in
            Button(pending.confirmTitle, role: .destructive) { Task { await remove(pending) } }
        } message: { pending in
            Text(pending.message)
        }
    }

    @ViewBuilder private func content(_ state: DockerState) -> some View {
        let confirm: (DockerRemoval) -> Void = { removal = $0 }
        if selection == DockerSelection.images {
            DockerImagesView(store: store, state: state, confirm: confirm)
        } else if let name = value(after: "project:"), let project = state.project(named: name) {
            DockerProjectView(store: store, project: project, select: select, confirm: confirm).id(project.id)
        } else if let id = value(after: "container:"), let container = state.container(id: id) {
            DockerContainerView(store: store, container: container, select: select, confirm: confirm)
                .id(container.id)
        } else if selection == DockerSelection.overview || selection == nil {
            DockerOverview(store: store, state: state, select: select, confirm: confirm)
        } else {
            ContentUnavailableView {
                Label("No longer listed", systemImage: "shippingbox")
            } description: {
                Text("Docker no longer lists this item. It may have been removed outside MacDev.")
            } actions: {
                Button("Show All Containers") { select(DockerSelection.overview) }
            }
        }
    }

    private func value(after prefix: String) -> String? {
        guard let selection, selection.hasPrefix(prefix) else { return nil }
        return String(selection.dropFirst(prefix.count))
    }

    private func remove(_ pending: DockerRemoval) async {
        switch pending {
        case .container(let container):
            await store.controlContainer(container, action: "remove")
            if store.docker?.container(id: container.id) == nil, selection == DockerSelection.container(container.id) {
                select(container.project.map(DockerSelection.project) ?? DockerSelection.overview)
            }
        case .image(let image): await store.removeImage(image)
        case .dangling: await store.pruneImages()
        }
    }
}

private struct DockerEngineStoppedView: View {
    @ObservedObject var store: SiteStore
    let state: DockerState

    var body: some View {
        ContentUnavailableView {
            Label("Docker is not running", systemImage: "shippingbox")
        } description: {
            VStack(spacing: 8) {
                Text(
                    store.dockerApp.map { "Open \($0.name) to start the Docker engine." }
                        ?? "Start your Docker engine, for example with `colima start`, then refresh.")
                if let error = state.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        } actions: {
            if let app = store.dockerApp {
                Button {
                    Task { await store.startDockerEngine() }
                } label: {
                    if store.isStartingDocker {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Starting \(app.name)…")
                        }
                    } else {
                        Text("Open \(app.name)")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.isStartingDocker)
            }
            Button("Check Again") { Task { await store.loadDocker(force: true) } }
                .disabled(store.isLoadingDocker || store.isStartingDocker)
        }
    }
}

// MARK: - Controls

/// Start or stop, with restart, details, and removal in a menu.
struct ContainerControls: View {
    @ObservedObject var store: SiteStore
    let container: DockerContainer
    var showDetails: (() -> Void)?
    let confirm: (DockerRemoval) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if container.isRunning, let url = container.browserURLs.first {
                Button {
                    store.openURL(url)
                } label: {
                    Image(systemName: "safari")
                }
                .help("Open \(url.absoluteString)").accessibilityLabel("Open \(container.name) in your browser")
            }
            Button(container.isRunning ? "Stop" : "Start") {
                Task { await store.controlContainer(container, action: container.isRunning ? "stop" : "start") }
            }
            .help(container.isRunning ? "Stop \(container.name)" : "Start \(container.name)")
            Menu {
                if let showDetails {
                    Button("Show Details", action: showDetails)
                    Divider()
                }
                Button("Restart") { Task { await store.controlContainer(container, action: "restart") } }
                    .disabled(!container.isRunning)
                Divider()
                Button("Copy Shell Command") {
                    store.copyToPasteboard(container.shellCommand, label: "shell command")
                }
                .disabled(!container.isRunning)
                Button("Copy Container ID") { store.copyToPasteboard(container.id, label: "container ID") }
                Divider()
                Button("Remove…", role: .destructive) { confirm(.container(container)) }
                    .disabled(!container.canRemove)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 24)
            .help(container.canRemove ? "More actions" : "More actions · stop the container to remove it")
            .accessibilityLabel("Actions for \(container.name)")
        }
        .disabled(store.isBusy || store.isLoadingDocker)
    }
}

/// Start, stop, and restart for every container of a Compose project.
struct ProjectControls: View {
    @ObservedObject var store: SiteStore
    let project: DockerProject
    var showDetails: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Button(project.runningCount == project.containers.count ? "Restart" : "Start") {
                let action = project.runningCount == project.containers.count ? "restart" : "start"
                Task { await store.controlProject(project, action: action) }
            }
            .help("Start every container of \(project.name), dependencies first")
            Button("Stop") { Task { await store.controlProject(project, action: "stop") } }
                .disabled(!project.isRunning)
                .help("Stop every container of \(project.name). Nothing is removed.")
            if let showDetails {
                Button {
                    showDetails()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless).help("Show \(project.name)").accessibilityLabel("Show \(project.name)")
            }
        }
        .disabled(store.isBusy || store.isLoadingDocker)
    }
}

/// One container in a project or overview panel.
private struct ContainerRow: View {
    @ObservedObject var store: SiteStore
    let container: DockerContainer
    let title: String
    let select: (String) -> Void
    let confirm: (DockerRemoval) -> Void

    var body: some View {
        HStack(spacing: 12) {
            StatusDot(color: container.statusColor)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).fontWeight(.medium)
                    Text(container.image ?? "").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 10) {
                    Text(container.statusTitle).foregroundStyle(container.hasError ? Color.red : Color.secondary)
                    if let ports = portSummary {
                        Text(ports).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
            }
            Spacer(minLength: 8)
            ContainerControls(
                store: store, container: container, showDetails: { select(DockerSelection.container(container.id)) },
                confirm: confirm)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { select(DockerSelection.container(container.id)) }
    }

    private var portSummary: String? {
        let published = container.ports.compactMap(\.hostPort)
        guard !published.isEmpty else { return nil }
        return published.map { ":\($0)" }.joined(separator: " ")
    }
}

// MARK: - Overview

private struct DockerOverview: View {
    @ObservedObject var store: SiteStore
    let state: DockerState
    let select: (String) -> Void
    let confirm: (DockerRemoval) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Containers").font(.title2.weight(.semibold))
                    HStack(spacing: 14) {
                        Label(
                            "\(state.runningCount) of \(state.containers.count) running",
                            systemImage: "shippingbox")
                        Label(engineTitle, systemImage: "cpu").help("docker context: \(state.context ?? "default")")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                if state.containers.isEmpty {
                    ContentUnavailableView(
                        "No containers", systemImage: "shippingbox",
                        description: Text("Containers you create with docker run or docker compose appear here."))
                }
                ForEach(state.projects) { project in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            StatusDot(color: project.statusColor)
                            Button(project.name) { select(DockerSelection.project(project.name)) }
                                .buttonStyle(.plain).font(.headline).help("Show \(project.name)")
                            Text(project.summary).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            ProjectControls(store: store, project: project)
                        }
                        WorkspacePanel { rows(project.containers, useServiceNames: true) }
                    }
                }
                if !state.standaloneContainers.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.projects.isEmpty ? "All Containers" : "Other Containers").font(.headline)
                        WorkspacePanel { rows(state.standaloneContainers, useServiceNames: false) }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1060, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var engineTitle: String {
        [state.platform ?? "Docker Engine", state.version.map { "Engine \($0)" }].compactMap { $0 }
            .joined(separator: " · ")
    }

    @ViewBuilder private func rows(_ containers: [DockerContainer], useServiceNames: Bool) -> some View {
        ForEach(Array(containers.enumerated()), id: \.element.id) { index, container in
            if index > 0 { Divider().padding(.horizontal, 16) }
            ContainerRow(
                store: store, container: container, title: useServiceNames ? container.displayName : container.name,
                select: select, confirm: confirm)
        }
    }
}

// MARK: - Project

private struct DockerProjectView: View {
    @ObservedObject var store: SiteStore
    let project: DockerProject
    let select: (String) -> Void
    let confirm: (DockerRemoval) -> Void

    private var upCommand: String {
        guard let folder = project.workingDir else { return "docker compose -p \(project.name) up -d" }
        return "cd \(shellQuoted(folder)) && docker compose up -d"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 18) {
                        heading
                        Spacer(minLength: 12)
                        ProjectControls(store: store, project: project)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        heading
                        ProjectControls(store: store, project: project)
                    }
                }
                Divider()
                section("Containers") {
                    ForEach(Array(project.containers.enumerated()), id: \.element.id) { index, container in
                        if index > 0 { Divider().padding(.horizontal, 16) }
                        ContainerRow(
                            store: store, container: container, title: container.displayName, select: select,
                            confirm: confirm)
                    }
                }
                section("Project") {
                    DetailRow("Folder") {
                        PathText(value: project.workingDir ?? "Unknown")
                        Spacer(minLength: 0)
                        if let folder = project.workingDir {
                            Button {
                                store.openFolder(folder)
                            } label: {
                                Label("Open in Finder", systemImage: "folder")
                            }
                        }
                    }
                    ForEach(project.configFiles, id: \.self) { file in
                        Divider().padding(.horizontal, 16)
                        DetailRow("Compose file") {
                            PathText(value: file)
                            Spacer(minLength: 0)
                            Button("Open") { store.openFile(file) }.help("Open \(file)")
                        }
                    }
                    Divider().padding(.horizontal, 16)
                    DetailRow("Apply changes") {
                        Text(upCommand).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            .lineLimit(1).truncationMode(.head).help(upCommand)
                        Spacer(minLength: 0)
                        Button("Copy") { store.copyToPasteboard(upCommand, label: "Compose command") }
                        ContextHelp(
                            "Start, Stop, and Restart act on the containers that already exist. After editing a Compose file, run this command in Terminal to recreate them. MacDev never runs Compose itself."
                        )
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1060, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(project.name).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 14) {
                Label {
                    Text(project.summary)
                } icon: {
                    StatusDot(color: project.statusColor)
                }
                Label("Compose project", systemImage: "square.stack.3d.down.right")
            }
            .font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Container

private struct DockerContainerView: View {
    @ObservedObject var store: SiteStore
    let container: DockerContainer
    let select: (String) -> Void
    let confirm: (DockerRemoval) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 18) {
                        heading
                        Spacer(minLength: 12)
                        ContainerControls(store: store, container: container, confirm: confirm)
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        heading
                        ContainerControls(store: store, container: container, confirm: confirm)
                    }
                }
                if container.hasError { problem }
                Divider()
                section("Container") { details }
                section("Network") { network }
                if !container.mounts.isEmpty { section("Storage") { storage } }
                if let project = container.project { section("Compose") { compose(project) } }
                section("Logs") {
                    ContainerLogPanel(store: store, container: container)
                }
            }
            .padding(20)
            .frame(maxWidth: 1060, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(container.name).font(.title2.weight(.semibold)).textSelection(.enabled)
                .lineLimit(1).truncationMode(.middle)
            HStack(spacing: 14) {
                Label {
                    Text(container.statusTitle)
                } icon: {
                    StatusDot(color: container.statusColor)
                }
                .foregroundStyle(container.hasError ? Color.red : Color.secondary)
                if let uptime = container.uptime() {
                    Label("Up \(uptime)", systemImage: "clock").foregroundStyle(.secondary)
                } else if let finished = container.finishedDate {
                    Label(
                        "Stopped \(finished.formatted(.relative(presentation: .named)))", systemImage: "clock"
                    )
                    .foregroundStyle(.secondary)
                }
                if let image = container.image {
                    Label(image, systemImage: "square.stack.3d.up").foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.callout)
        }
    }

    private var problem: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 4) {
                Text(container.statusTitle).fontWeight(.medium)
                Text(problemDetail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private var problemDetail: String {
        if let error = container.error { return error }
        if container.oomKilled {
            return
                "The container used more memory than Docker allows it. Raise the memory limit in your Docker app or the Compose file."
        }
        if container.currentHealth == "unhealthy" {
            return "The container runs, but its health check fails. The logs below may show why."
        }
        return "The main process stopped on its own. The logs below usually show why."
    }

    @ViewBuilder private var details: some View {
        DetailRow("ID") {
            Text(container.shortID).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                .help(container.id)
            Spacer(minLength: 0)
            Button("Copy") { store.copyToPasteboard(container.id, label: "container ID") }
        }
        Divider().padding(.horizontal, 16)
        DetailRow("Image") {
            Text(container.image ?? "Unknown").textSelection(.enabled)
            Spacer(minLength: 0)
            Button("Show Images") { select(DockerSelection.images) }
        }
        if let command = container.command {
            Divider().padding(.horizontal, 16)
            DetailRow("Command") {
                PathText(value: command)
                Spacer(minLength: 0)
            }
        }
        Divider().padding(.horizontal, 16)
        DetailRow("Restart") {
            Text(restartTitle)
            Spacer(minLength: 0)
            ContextHelp(
                "Docker’s restart policy. Containers that restart automatically come back when the Docker engine starts."
            )
        }
        if let created = container.createdDate {
            Divider().padding(.horizontal, 16)
            DetailRow("Created") {
                Text(created.formatted(date: .abbreviated, time: .shortened))
                Spacer(minLength: 0)
            }
        }
        if container.isRunning {
            Divider().padding(.horizontal, 16)
            DetailRow("Shell") {
                Text(container.shellCommand).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Spacer(minLength: 0)
                Button("Copy") { store.copyToPasteboard(container.shellCommand, label: "shell command") }
                    .help("Copy this command, then run it in Terminal")
            }
        }
    }

    private var restartTitle: String {
        switch container.restartPolicy {
        case "always": "Always"
        case "unless-stopped": "Unless stopped by you"
        case "on-failure": "When it fails"
        default: "Never"
        }
    }

    @ViewBuilder private var network: some View {
        if container.ports.isEmpty {
            DetailRow("Ports") {
                Text("No published ports · reachable only from other containers").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        } else {
            ForEach(Array(container.ports.enumerated()), id: \.offset) { index, port in
                if index > 0 { Divider().padding(.horizontal, 16) }
                DetailRow(index == 0 ? "Ports" : "") {
                    Text(port.summary).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if container.isRunning, let url = port.browserURL {
                        Button("Open") { store.openURL(url) }.help("Open \(url.absoluteString) in your browser")
                    }
                }
            }
        }
    }

    @ViewBuilder private var storage: some View {
        ForEach(Array(container.mounts.enumerated()), id: \.offset) { index, mount in
            if index > 0 { Divider().padding(.horizontal, 16) }
            DetailRow(mount.isBind ? "Folder" : mount.type.capitalized) {
                VStack(alignment: .leading, spacing: 2) {
                    PathText(value: mount.origin)
                    Text("→ \(mount.destination)\(mount.readOnly ? " · read-only" : "")")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer(minLength: 0)
                if mount.isBind, let source = mount.source {
                    Button("Show in Finder") { store.revealFile(source) }
                }
            }
        }
    }

    @ViewBuilder private func compose(_ project: String) -> some View {
        DetailRow("Project") {
            Button(project) { select(DockerSelection.project(project)) }.buttonStyle(.link)
            Spacer(minLength: 0)
        }
        if let service = container.service {
            Divider().padding(.horizontal, 16)
            DetailRow("Service") {
                Text(service).textSelection(.enabled)
                Spacer(minLength: 0)
            }
        }
        if !container.dependsOn.isEmpty {
            Divider().padding(.horizontal, 16)
            DetailRow("Depends on") {
                Text(container.dependsOn.joined(separator: ", "))
                Spacer(minLength: 0)
                ContextHelp("Starting the project starts these services first; stopping it stops them last.")
            }
        }
    }
}

/// The container's recent output, re-read whenever it starts or stops.
private struct ContainerLogPanel: View {
    @ObservedObject var store: SiteStore
    let container: DockerContainer
    @State private var lines: [String]?
    @State private var error: String?
    @State private var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if let lines {
                ScrollView([.vertical, .horizontal]) {
                    Text(lines.isEmpty ? "This container has not written any output." : lines.joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(lines.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .defaultScrollAnchor(.bottom)
                .frame(minHeight: 120, maxHeight: 320)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Text(lines.map { "Last \($0.count) \($0.count == 1 ? "line" : "lines") of stdout and stderr" } ?? "")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reload") { Task { await load() } }.controlSize(.small).disabled(isLoading)
            }
        }
        .padding(16)
        .task(id: "\(container.state)|\(container.startedAt ?? "")") { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        switch await store.readContainerLog(container) {
        case .success(let log):
            lines = log.lines
            error = nil
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }
}

// MARK: - Images

private struct DockerImagesView: View {
    @ObservedObject var store: SiteStore
    let state: DockerState
    let confirm: (DockerRemoval) -> Void

    private var totalSize: Int64 { state.images.compactMap(\.size).reduce(0, +) }
    private var dangling: [DockerImage] { state.images.filter { $0.isDangling && $0.containers == 0 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Images").font(.title2.weight(.semibold))
                        Label(
                            "\(state.images.count) \(state.images.count == 1 ? "image" : "images") · \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))",
                            systemImage: "square.stack.3d.up"
                        )
                        .font(.callout).foregroundStyle(.secondary)
                        .help("Images that share layers are counted in full, so disk use may be lower.")
                    }
                    Spacer(minLength: 12)
                    Button("Remove Dangling Images…") {
                        confirm(.dangling(count: dangling.count, size: dangling.compactMap(\.size).reduce(0, +)))
                    }
                    .disabled(dangling.isEmpty || store.isBusy || store.isLoadingDocker)
                    .help(
                        dangling.isEmpty
                            ? "No untagged images are unused"
                            : "Remove untagged images that no container uses")
                }
                Divider()
                if state.images.isEmpty {
                    ContentUnavailableView(
                        "No images", systemImage: "square.stack.3d.up",
                        description: Text("Images you pull or build appear here."))
                } else {
                    WorkspacePanel {
                        ForEach(Array(state.images.enumerated()), id: \.element.id) { index, image in
                            if index > 0 { Divider().padding(.horizontal, 16) }
                            row(image)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 1060, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ image: DockerImage) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(image.title).fontWeight(.medium).foregroundStyle(image.isDangling ? .secondary : .primary)
                    .textSelection(.enabled)
                Text(caption(image)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(image.sizeSummary ?? "").monospacedDigit().foregroundStyle(.secondary)
            Button("Remove…") { confirm(.image(image)) }
                .disabled(image.containers > 0 || store.isBusy || store.isLoadingDocker)
                .help(
                    image.containers > 0
                        ? "Used by \(usage(image)). Remove those containers first."
                        : "Remove \(image.title)")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func caption(_ image: DockerImage) -> String {
        [
            image.tags.count > 1 ? "Also \(image.tags.dropFirst().joined(separator: ", "))" : nil,
            image.shortID,
            image.createdDate.map { "Created \($0.formatted(.relative(presentation: .named)))" },
            image.containers > 0 ? "Used by \(usage(image))" : "Unused",
        ]
        .compactMap { $0 }.joined(separator: " · ")
    }

    private func usage(_ image: DockerImage) -> String {
        let names = state.containers(using: image).map(\.name)
        if names.count == 1, let name = names.first { return name }
        return "\(image.containers) containers"
    }
}

@MainActor private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        Text(title).font(.headline)
        WorkspacePanel { content() }
    }
}

/// Single-quotes a path for a Terminal command.
private func shellQuoted(_ value: String) -> String {
    value.allSatisfy { $0.isLetter || $0.isNumber || "/._-~".contains($0) }
        ? value : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
