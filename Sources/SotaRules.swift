import AppKit
import Foundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct Policy: Codable, Equatable {
    var vpnOnly: [String] = []
    var notVPNOnly: [String] = []
    var vpnProfile: String?

    enum CodingKeys: String, CodingKey {
        case vpnOnly = "vpn_only"
        case notVPNOnly = "not_vpn_only"
        case vpnProfile = "vpn_profile"
    }

    static func isDomain(_ address: String) -> Bool {
        guard !address.contains(":"), !address.contains("/") else { return false }
        var ipv4 = in_addr()
        return address.withCString { inet_pton(AF_INET, $0, &ipv4) != 1 }
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> Policy {
        try JSONDecoder().decode(Policy.self, from: Data(contentsOf: url))
    }
}

struct FirewallState: Decodable {
    let installed: Bool
    let running: Bool
    let confirmed: Bool
    let unresolved: [String]?
    let discovery: VPNDiscovery?
}

struct VPNProfile: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String
    let enabled: Bool
}

struct VPNDiscovery: Decodable {
    let profiles: [VPNProfile]
    let profileName: String?
    let vpnStatus: String
    let tunnel: String?
    let vpnIssue: String?
}

enum Backend {
    static let python = URL(fileURLWithPath: "/usr/bin/python3")
    static let activeConfig = URL(fileURLWithPath: "/Library/Application Support/SotaSelectivePolicy/policy.json")

    static var script: URL? {
        Bundle.main.url(forResource: "sota-policy", withExtension: "py")
    }

    static func output(from executable: URL, arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    static func readState(profile: String) -> (FirewallState?, Policy?) {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let firewall: FirewallState? = script.flatMap {
            output(from: python, arguments: ["-I", $0.path, "status", "--profile", profile])
        }.flatMap { try? decoder.decode(FirewallState.self, from: $0) }
        return (firewall, try? Policy.read(from: activeConfig))
    }

    static func validate(_ policy: Policy) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try policy.write(to: temporary)
        try validate(config: temporary)
    }

    static func validate(config: URL) throws {
        guard let script else { throw AppError("The firewall component is missing from this app.") }
        let process = Process()
        let output = Pipe()
        process.executableURL = python
        process.arguments = ["-I", script.path, "validate", config.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw AppError(message.isEmpty ? "Could not validate the address rules." : message)
        }
    }

    static func installedVPNApps() -> [String] {
        let manager = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications"), manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let hints = ["vpn", "sota connect", "tailscale", "wireguard", "tunnelblick", "viscosity", "amnezia", "warp", "sing-box", "hiddify"]
        var clients = Set<String>()
        for root in roots {
            let apps = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
            for app in apps where app.pathExtension == "app" {
                guard Bundle(url: app)?.bundleIdentifier != Bundle.main.bundleIdentifier else { continue }
                let name = app.deletingPathExtension().lastPathComponent
                let plugins = (try? manager.contentsOfDirectory(at: app.appendingPathComponent("Contents/PlugIns"), includingPropertiesForKeys: nil)) ?? []
                let hasTunnel = plugins.contains { plugin in
                    let extensionInfo = Bundle(url: plugin)?.infoDictionary?["NSExtension"] as? [String: Any]
                    return (extensionInfo?["NSExtensionPointIdentifier"] as? String) == "com.apple.networkextension.packet-tunnel"
                }
                if hasTunnel || hints.contains(where: name.lowercased().contains) { clients.insert(name) }
            }
        }
        return clients.sorted()
    }

    @MainActor
    static func change(_ action: String, config: URL) throws {
        guard let script else { throw AppError("The firewall component is missing from this app.") }
        func shellQuote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }
        let command = [python.path, "-I", script.path, action, config.path]
            .map(shellQuote).joined(separator: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        guard let appleScript = NSAppleScript(source: "do shell script \"\(command)\" with administrator privileges") else {
            throw AppError("Could not prepare the macOS authorization request.")
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            if (error[NSAppleScript.errorNumber] as? Int) == -128 { throw CancellationError() }
            throw AppError(error[NSAppleScript.errorMessage] as? String ?? "macOS did not apply the change.")
        }
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

@MainActor
final class RuleModel: ObservableObject {
    @Published private(set) var policy = Policy()
    @Published private(set) var firewall: FirewallState?
    @Published private(set) var didCheckFirewall = false
    @Published private(set) var installedClients: [String] = []
    @Published private(set) var loginStatus: SMAppService.Status = .notRegistered
    @Published private(set) var appliedPolicy: Policy?
    @Published private(set) var busy = false
    @Published var error: String?
    @Published var notice: String?

    private let draftURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        draftURL = support.appendingPathComponent("RouteSentry/policy.json")
        let previousDraft = support
            .appendingPathComponent("Sota Rules/policy.json")
        let saved = (try? Policy.read(from: draftURL)) ?? (try? Policy.read(from: previousDraft))
            ?? (try? Policy.read(from: Backend.activeConfig)) ?? Policy()
        policy = Self.normalizedProfile(in: saved)
        loginStatus = SMAppService.mainApp.status
        Task { [weak self] in
            let clients = await Task.detached(priority: .utility) { Backend.installedVPNApps() }.value
            self?.installedClients = clients
            while self != nil && !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    var selection: String { policy.vpnProfile ?? "auto" }

    var hasEntries: Bool { !policy.vpnOnly.isEmpty || !policy.notVPNOnly.isEmpty }

    var hasPendingChanges: Bool {
        guard let appliedPolicy, firewall?.confirmed == true else { return false }
        return Set(policy.vpnOnly) != Set(appliedPolicy.vpnOnly)
            || Set(policy.notVPNOnly) != Set(appliedPolicy.notVPNOnly)
            || selection != (appliedPolicy.vpnProfile ?? "auto")
    }

    private static func normalizedProfile(in policy: Policy) -> Policy {
        var normalized = policy
        let selection = policy.vpnProfile ?? "auto"
        normalized.vpnProfile = ["auto", "route"].contains(selection) ? selection : selection.uppercased()
        return normalized
    }

    private func save(_ nextPolicy: Policy) throws {
        try FileManager.default.createDirectory(at: draftURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try nextPolicy.write(to: draftURL)
        policy = nextPolicy
    }

    func selectProfile(_ profile: String) {
        guard profile != selection, !busy else { return }
        var nextPolicy = policy
        nextPolicy.vpnProfile = profile
        do {
            try save(Self.normalizedProfile(in: nextPolicy))
            Task { await refresh() }
        } catch { self.error = error.localizedDescription }
    }

    func addAddresses(_ input: String, to list: WritableKeyPath<Policy, [String]>) throws {
        let tokens = input.split { $0.isWhitespace || $0 == "," || $0 == ";" }
        guard !tokens.isEmpty else { throw AppError("Enter a domain, IP address, or CIDR.") }
        var nextPolicy = policy
        var seen = Set(nextPolicy[keyPath: list].map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        for token in tokens {
            let address = String(token).lowercased()
            let key = address.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard seen.insert(key).inserted else { throw AppError("\(address) is already in this list.") }
            nextPolicy[keyPath: list].append(address)
        }
        try Backend.validate(nextPolicy)
        try save(nextPolicy)
    }

    func removeAddress(_ address: String, from list: WritableKeyPath<Policy, [String]>) {
        var nextPolicy = policy
        nextPolicy[keyPath: list].removeAll { $0 == address }
        do { try save(nextPolicy) } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        let currentSelection = selection
        let state = await Task.detached(priority: .utility) { Backend.readState(profile: currentSelection) }.value
        guard selection == currentSelection else { return }
        firewall = state.0
        didCheckFirewall = true
        appliedPolicy = state.1
        loginStatus = SMAppService.mainApp.status
    }

    func change(_ action: String) async {
        guard !busy else { return }
        busy = true
        notice = nil
        defer { busy = false }
        do {
            try save(policy)
            try Backend.change(action, config: draftURL)
            notice = action == "install" ? "Rules applied." : "Protection off. Your lists are saved."
        } catch is CancellationError {
            notice = "Action canceled."
        } catch {
            self.error = error.localizedDescription
        }
        await refresh()
    }

    func changeLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            if service.status != .requiresApproval { self.error = error.localizedDescription }
        }
        loginStatus = service.status
    }

    func importPolicy() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.title = "Import RouteSentry Configuration"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Backend.validate(config: url)
            let imported = Self.normalizedProfile(in: try Policy.read(from: url))
            try save(imported)
            notice = "Configuration imported."
            Task { await refresh() }
        } catch { self.error = error.localizedDescription }
    }

    func exportPolicy() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "routesentry-config.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try policy.write(to: url) } catch { self.error = error.localizedDescription }
    }
}

private struct StatusMenu: View {
    @ObservedObject var model: RuleModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.discovery?.profileName.map { "\($0) · \(model.vpnLabel)" } ?? model.vpnLabel)
        Text(model.firewallLabel)
        Divider()
        Button("Open RouteSentry") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit RouteSentry") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@main
struct RouteSentryApp: App {
    @StateObject private var model = RuleModel()

    private static let menuGlyph: NSImage = {
        let icon = NSImage(size: NSSize(width: 16, height: 17), flipped: true) { _ in
            NSColor.black.setFill()
            for points in [[(8.0, 1.0), (11.1, 2.7), (4.5, 14.1), (1.4, 9.6), (1.4, 4.6)],
                           [(12.6, 3.5), (14.6, 4.6), (14.6, 9.6), (12.3, 13.0), (8.0, 16.0), (6.0, 14.9)]] {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: points[0].0, y: points[0].1))
                for point in points.dropFirst() { path.line(to: NSPoint(x: point.0, y: point.1)) }
                path.close()
                path.fill()
            }
            return true
        }
        icon.isTemplate = true
        return icon
    }()

    var body: some Scene {
        Window("RouteSentry", id: "main") { RouteSentryView(model: model) }
            .defaultSize(width: 390, height: 740)
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
        MenuBarExtra {
            StatusMenu(model: model)
        } label: {
            Image(nsImage: Self.menuGlyph).accessibilityLabel("RouteSentry")
        }
    }
}
