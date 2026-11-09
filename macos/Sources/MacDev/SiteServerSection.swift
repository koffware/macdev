import MacDevCore
import SwiftUI

/// Certificate, request limits, and logs for one site: the facts that explain failing requests.
struct SiteServerSection: View {
    @ObservedObject var store: SiteStore
    let site: Site

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Server").font(.headline)
            WorkspacePanel {
                DetailRow("Certificate") { certificate }
                Divider().padding(.horizontal, 16)
                DetailRow("Upload size") {
                    limitSummary(
                        nginx: limits.nginxBody.map(ConfigValue.size) ?? "default (1 MB)",
                        php: limits.phpUpload.map(ConfigValue.size),
                        warning: limits.uploadWarning)
                    Spacer(minLength: 0)
                    ContextHelp(
                        "nginx’s client_max_body_size for this site, and the smaller of PHP’s upload_max_filesize and post_max_size. Change the PHP values for all sites using this version on the PHP page."
                    )
                }
                if site.fpm != nil {
                    Divider().padding(.horizontal, 16)
                    DetailRow("Request timeout") {
                        limitSummary(
                            nginx: limits.nginxTimeout.map(ConfigValue.duration) ?? "default (60 s)",
                            php: limits.executionTime.map(ConfigValue.duration),
                            warning: limits.timeoutWarning)
                        Spacer(minLength: 0)
                        ContextHelp(
                            "How long nginx waits for PHP-FPM (fastcgi_read_timeout), and PHP’s max_execution_time. PHP counts only the time it spends running, not time waiting for databases or other services."
                        )
                    }
                }
                ForEach(site.logs ?? []) { log in
                    Divider().padding(.horizontal, 16)
                    LogFileRow(
                        title: log.title, path: log.path, exists: log.exists, size: log.size,
                        modified: log.modifiedDate, open: { store.openFile(log.path) },
                        read: { await store.readLog(site, kind: log.kind) }
                    )
                    .id("\(site.id)-\(log.kind)")
                }
            }
        }
    }

    private var limits: RequestLimits { RequestLimits(site: site, phpSettings: store.phpSettings(for: site)) }

    @ViewBuilder private var certificate: some View {
        if site.certificate == nil {
            Label("None · served over HTTP only", systemImage: "lock.open").foregroundStyle(.secondary)
        } else {
            let health = site.certificateHealth() ?? .ok
            Label {
                Text(certificateText(health))
            } icon: {
                HealthDot(health: health)
            }
            .foregroundStyle(health == .ok ? .primary : health.color)
            if let names = site.certificateNames, !names.isEmpty {
                Text("· \(names.joined(separator: ", "))").foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail).help("Names this certificate is valid for")
            }
        }
        Spacer(minLength: 0)
        ContextHelp(
            "MacDev reads the certificate named in the nginx configuration. A missing certificate or key file stops nginx from reloading for every site. Local certificates come from mkcert."
        )
    }

    private func certificateText(_ health: SiteHealth) -> String {
        guard health == .ok else { return health.message }
        guard let expiry = site.certificateExpiryDate else { return "Configured" }
        return "Valid until \(expiry.formatted(date: .abbreviated, time: .omitted))"
    }

    private func limitSummary(nginx: String, php: String?, warning: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                site.fpm == nil
                    ? "nginx \(nginx)"
                    : "nginx \(nginx) · PHP \(php ?? (store.phpSettings(for: site) == nil ? "loading…" : "unknown"))")
            if let warning {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(warning).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }
}
