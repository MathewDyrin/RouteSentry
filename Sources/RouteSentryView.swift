import AppKit
import ServiceManagement
import SwiftUI

private let ink = Color(white: 0.93)
private let muted = Color(white: 0.67)
private let line = Color(white: 0.17)
private let activeGreen = Color(red: 0.45, green: 0.96, blue: 0.66)

enum RuleList: Hashable {
    case vpnOn, vpnOff

    var title: String { self == .vpnOn ? "VPN On Only" : "VPN Off Only" }
    var glyph: Glyph { self == .vpnOn ? .vpnOn : .vpnOff }
    var addresses: WritableKeyPath<Policy, [String]> { self == .vpnOn ? \.vpnOnly : \.notVPNOnly }
    var explanation: String {
        self == .vpnOn
            ? "Block these addresses outside the VPN tunnel."
            : "Block these addresses while the VPN is connected."
    }
}

enum Glyph: String, CaseIterable {
    case logo, gear, profile, vpnOn = "vpn_only", vpnOff = "not_vpn_only"
    case importConfig = "import", exportConfig = "export", login, auto, route, specific, add

    private static let images = Dictionary(uniqueKeysWithValues: allCases.compactMap { glyph in
        Bundle.main.url(forResource: glyph.rawValue, withExtension: "png", subdirectory: "Glyphs")
            .flatMap(NSImage.init(contentsOf:))
            .map { (glyph, $0) }
    })

    @ViewBuilder
    func view(_ size: CGFloat = 18) -> some View {
        if let image = Self.images[self] {
            Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
                .frame(width: size, height: size).accessibilityHidden(true)
        }
    }
}

extension RuleModel {
    var discovery: VPNDiscovery? { firewall?.discovery }

    var profileTitle: String {
        switch selection {
        case "auto": "Automatic"
        case "route": "Routed tunnel"
        default: discovery?.profiles.first(where: { $0.id == selection })?.name ?? "Unavailable profile"
        }
    }

    var vpnLabel: String {
        switch discovery?.vpnIssue {
        case "ambiguous": return "Multiple active VPN profiles"
        case "missing": return "No VPN profile found"
        case "idle": return "Disconnected"
        case "no_interface": return "Tunnel interface unavailable"
        case "route_unclear": return "VPN route could not be verified"
        default: break
        }
        guard let discovery else { return didCheckFirewall ? "Status unavailable" : "Checking VPN profiles…" }
        return switch discovery.vpnStatus {
        case "Connected": "Connected"
        case "Disconnected", "Invalid": "Disconnected"
        case "Connecting", "Reasserting": "Connecting"
        case "Disconnecting": "Disconnecting"
        default: "Status unknown"
        }
    }

    var protectionOn: Bool { firewall?.confirmed == true }

    var firewallLabel: String {
        guard let firewall else { return didCheckFirewall ? "Status Unavailable" : "Checking protection…" }
        if protectionOn { return "Protection On" }
        return firewall.installed ? "Protection Unverified" : "Protection Off"
    }

    var firewallDetail: String {
        if busy { return "Updating protection…" }
        guard let firewall else {
            return didCheckFirewall ? "The firewall status could not be read." : "Reading firewall status…"
        }
        if protectionOn { return "Rules are active" }
        return firewall.installed ? "The firewall could not be verified." : "Rules are paused"
    }
}

struct RouteSentryView: View {
    @ObservedObject var model: RuleModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var screen: Screen = .home

    private enum Screen: Hashable {
        case home, settings, profile, rules(RuleList)
    }

    var body: some View {
        ZStack {
            currentScreen
                .id(screen)
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
        }
        .clipped()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: screen)
        .padding(.top, 24)
        .frame(width: 390)
        .frame(minHeight: 560, idealHeight: 740, maxHeight: 740)
        .foregroundStyle(ink)
        .background(.black)
        .preferredColorScheme(.dark)
        .alert("Could not complete the action", isPresented: Binding(
            get: { model.error != nil }, set: { if !$0 { model.error = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error ?? "")
        }
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch screen {
        case .home:
            ProtectionView(model: model) { screen = .settings }
        case .settings:
            VStack(spacing: 0) {
                ScreenHeader(title: "Settings", icon: .gear, backLabel: "Back to Protection") { screen = .home }
                SettingsView(model: model, openProfile: { screen = .profile }, openRules: { screen = .rules($0) })
            }
        case .profile:
            VStack(spacing: 0) {
                ScreenHeader(title: "VPN Profile", icon: .profile, backLabel: "Back to Settings") { screen = .settings }
                ProfileView(model: model)
            }
        case .rules(let list):
            VStack(spacing: 0) {
                ScreenHeader(title: list.title, icon: list.glyph, backLabel: "Back to Settings") { screen = .settings }
                RuleListView(model: model, list: list)
            }
        }
    }
}

private struct ScreenHeader: View {
    let title: String
    let icon: Glyph
    let backLabel: String
    let goBack: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            icon.view(18)
            Text(title).font(.system(size: 14, weight: .semibold))
        }
        .accessibilityAddTraits(.isHeader)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) {
            Button(action: goBack) {
                Image(systemName: "chevron.left").font(.system(size: 14, weight: .medium))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(backLabel)
            .help(backLabel)
            .padding(.leading, 17)
        }
        .frame(height: 49)
    }
}

private struct RouteButton: ButtonStyle {
    var primary = false
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8)
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, compact ? 9 : 12)
            .frame(maxWidth: .infinity)
            .frame(height: compact ? 34 : 43)
            .foregroundStyle(primary && enabled ? Color.black : ink)
            .background(primary && enabled ? Color(white: 0.96) : Color(white: 0.07), in: shape)
            .overlay(shape.strokeBorder(primary && enabled ? Color.clear : line))
            .opacity(configuration.isPressed || !enabled ? 0.58 : 1)
            .contentShape(shape)
    }
}

private struct ProtectionView: View {
    @ObservedObject var model: RuleModel
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Glyph.logo.view(24)
                Text("RouteSentry").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: openSettings) {
                    Glyph.gear.view(20)
                        .frame(width: 32, height: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
                .help("Settings")
            }
            .padding(.horizontal, 24)
            .frame(height: 49)

            VStack(spacing: 20) {
                ProtectionRing(on: model.protectionOn, title: model.firewallLabel, detail: model.firewallDetail)
                    .frame(minHeight: 180)
                Button(action: openSettings) {
                    HStack(spacing: 7) {
                        Glyph.profile.view(17).foregroundStyle(muted)
                        Text("VPN source").font(.system(size: 11)).foregroundStyle(muted)
                        Text(model.discovery?.profileName ?? model.profileTitle)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1).layoutPriority(1)
                        Spacer(minLength: 4)
                        Circle().fill(muted).frame(width: 5, height: 5).accessibilityHidden(true)
                        Text(model.vpnLabel).font(.system(size: 11)).foregroundStyle(muted)
                            .lineLimit(2).multilineTextAlignment(.trailing)
                        Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(muted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("VPN settings")
                .frame(minHeight: 26)

                HStack(alignment: .top, spacing: 18) {
                    RuleCount(list: .vpnOn, addresses: model.policy.vpnOnly)
                    RuleCount(list: .vpnOff, addresses: model.policy.notVPNOnly)
                }
                actions
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if let unresolved = model.firewall?.unresolved, !unresolved.isEmpty {
                Text("No DNS answer for \(unresolved.joined(separator: ", ")).")
                    .font(.system(size: 11)).foregroundStyle(muted).lineLimit(2)
            }
            if model.hasPendingChanges {
                Button("Apply Changes") { Task { await model.change("install") } }
                    .buttonStyle(RouteButton(primary: true))
                    .disabled(model.busy || !model.hasEntries)
            }
            if model.firewall?.installed == true {
                if !model.protectionOn && model.hasEntries {
                    Button("Retry Protection") { Task { await model.change("install") } }
                        .buttonStyle(RouteButton(primary: true))
                        .disabled(model.busy)
                }
                Button("Disable Protection") { Task { await model.change("uninstall") } }
                    .buttonStyle(RouteButton())
                    .disabled(model.busy)
            } else {
                if !model.hasEntries {
                    Text("Add addresses in Settings to enable protection.")
                        .font(.system(size: 11)).foregroundStyle(muted)
                }
                Button("Enable Protection") { Task { await model.change("install") } }
                    .buttonStyle(RouteButton(primary: true))
                    .disabled(model.busy || model.firewall == nil || !model.hasEntries)
            }
        }
    }
}

private struct ProtectionRing: View {
    let on: Bool
    let title: String
    let detail: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private static let image = Bundle.main.url(forResource: "protection-ring", withExtension: "png")
        .flatMap(NSImage.init(contentsOf:))

    var body: some View {
        GeometryReader { geometry in
            let size = min(362, geometry.size.height)
            ZStack {
                if let image = Self.image {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || scenePhase != .active)) { context in
                        let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                        let rotation = time.truncatingRemainder(dividingBy: 36) / 36
                        let pulse = 0.5 - 0.5 * cos(time * .pi / 3.5)
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: size, height: size)
                            .rotationEffect(.degrees(rotation * 360))
                            .scaleEffect(1 + 0.018 * pulse)
                            .colorMultiply(on ? activeGreen : .white)
                            .opacity(on ? 0.86 + 0.14 * pulse : 0.53 + 0.09 * pulse)
                    }
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
                }
                VStack(spacing: 7) {
                    Text(title).font(.system(size: 24, weight: .semibold))
                        .tracking(-0.6).foregroundStyle(on ? activeGreen : ink)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text(detail).font(.system(size: 12)).foregroundStyle(muted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.32), value: on)
        }
    }
}

private struct RuleCount: View {
    let list: RuleList
    let addresses: [String]

    var body: some View {
        let domains = addresses.filter(Policy.isDomain).count
        let networks = addresses.count - domains
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                list.glyph.view(17)
                Text(list.title).font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(muted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(domains.formatted()).font(.system(size: 32, weight: .semibold)).monospacedDigit()
                Text(domains == 1 ? "domain" : "domains").font(.system(size: 12)).foregroundStyle(muted)
            }
            if networks > 0 {
                Text(networks == 1 ? "+ 1 IP or range" : "+ \(networks) IPs or ranges")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsView: View {
    @ObservedObject var model: RuleModel
    let openProfile: () -> Void
    let openRules: (RuleList) -> Void

    private var buildText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        return "Version \(version) · Build \(build)"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    settingsLink("VPN Profile", detail: "Choose which VPN to monitor.", icon: .profile,
                                 value: model.profileTitle, action: openProfile)
                    Divider()
                    ruleLink(.vpnOn)
                    Divider()
                    ruleLink(.vpnOff)
                    Divider()
                    loginRow
                    Divider()
                    configRow("Import Configuration", detail: "Replace your address rules from a JSON file.",
                              icon: .importConfig, actionTitle: "Choose File…", action: model.importPolicy)
                    Divider()
                    configRow("Export Configuration", detail: "Save your rules and VPN profile as JSON.",
                              icon: .exportConfig, actionTitle: "Save JSON", action: model.exportPolicy)
                    if let notice = model.notice {
                        Text(notice).font(.system(size: 12)).foregroundStyle(muted)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }
                .padding(.horizontal, 24).padding(.top, 8)
            }
            Text(buildText).font(.system(size: 12)).foregroundStyle(muted)
                .padding(.top, 14).padding(.bottom, 22)
        }
    }

    private var loginRow: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 10) {
                RowLabel(title: "Launch at Login", detail: "Open RouteSentry when you log in to macOS.", icon: .login)
                Spacer(minLength: 0)
                Toggle("Launch at Login", isOn: Binding(
                    get: { model.loginStatus == .enabled || model.loginStatus == .requiresApproval },
                    set: model.changeLogin
                ))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .accessibilityHint("Open RouteSentry when you log in to macOS.")
            }
            if model.loginStatus == .requiresApproval {
                Button("Approve in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(.vertical, 10)
        .frame(minHeight: 56)
    }

    private func ruleLink(_ list: RuleList) -> some View {
        let count = model.policy[keyPath: list.addresses].count
        return settingsLink(list.title, detail: list.explanation, icon: list.glyph,
                            value: count == 1 ? "1 address" : "\(count) addresses") { openRules(list) }
    }

    private func settingsLink(_ title: String, detail: String, icon: Glyph, value: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                RowLabel(title: title, detail: detail, icon: icon)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Text(value).font(.system(size: 12)).lineLimit(2).multilineTextAlignment(.trailing)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium))
                }
                .foregroundStyle(muted).frame(maxWidth: 108, alignment: .trailing)
            }
            .padding(.vertical, 9)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(value)
        .accessibilityHint(detail)
    }

    private func configRow(_ title: String, detail: String, icon: Glyph, actionTitle: String,
                           action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            RowLabel(title: title, detail: detail, icon: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(actionTitle, action: action)
                .buttonStyle(RouteButton(compact: true))
                .frame(width: 100)
                .accessibilityHint(detail)
        }
        .padding(.vertical, 9)
        .frame(minHeight: 56)
    }
}

private struct RowLabel: View {
    let title: String
    let detail: String
    let icon: Glyph

    var body: some View {
        HStack(spacing: 10) {
            icon.view().foregroundStyle(Color(white: 0.82))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ProfileView: View {
    @ObservedObject var model: RuleModel

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                option("Automatic", value: "auto", icon: .auto)
                Divider()
                option("Routed tunnel", value: "route", icon: .route)
                ForEach(model.discovery?.profiles ?? []) { profile in
                    Divider()
                    option(profile.name, value: profile.id, icon: .specific)
                }
                if !["auto", "route"].contains(model.selection),
                   model.discovery?.profiles.contains(where: { $0.id == model.selection }) != true {
                    Divider()
                    option("Unavailable profile", value: model.selection, icon: .specific)
                }
                let profileNames = Set(model.discovery?.profiles.map { $0.name.lowercased() } ?? [])
                let clients = model.installedClients.filter { !profileNames.contains($0.lowercased()) }
                if !clients.isEmpty {
                    Text("Installed clients without a matching profile: \(clients.joined(separator: ", "))")
                        .font(.system(size: 11)).foregroundStyle(muted)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 15)
                }
            }
            .padding(.horizontal, 24).padding(.top, 8)
        }
    }

    private func option(_ title: String, value: String, icon: Glyph) -> some View {
        let selected = model.selection == value
        return Button {
            model.selectProfile(value)
        } label: {
            HStack(spacing: 10) {
                icon.view().foregroundStyle(Color(white: 0.82))
                Text(title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15)).foregroundStyle(selected ? ink : muted).accessibilityHidden(true)
            }
            .frame(minHeight: 55)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct RuleListView: View {
    @ObservedObject var model: RuleModel
    let list: RuleList
    @State private var editing = false
    @State private var input = ""
    @State private var validationError: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(list.explanation).font(.system(size: 12)).foregroundStyle(muted)
                    let addresses = model.policy[keyPath: list.addresses]
                    if addresses.isEmpty {
                        Text("No addresses yet.").font(.system(size: 12)).foregroundStyle(muted)
                    } else {
                        AddressFlow(spacing: 7) {
                            ForEach(Array(addresses.enumerated()), id: \.offset) { _, address in
                                chip(address)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: 7) {
                if editing {
                    HStack(spacing: 8) {
                        TextField("Domain, IP address, or CIDR", text: $input)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(.horizontal, 10)
                            .frame(height: 43)
                            .background(Color(white: 0.05), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(focused ? muted : line))
                            .accessibilityLabel("Addresses")
                            .focused($focused)
                            .onAppear { focused = true }
                            .onSubmit(save)
                            .onChange(of: input) { validationError = nil }
                        Button("Save", action: save)
                            .buttonStyle(RouteButton(primary: true)).frame(width: 63)
                            .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let validationError {
                        Text(validationError).font(.system(size: 12)).foregroundStyle(ink)
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                } else {
                    Button {
                        editing = true
                    } label: {
                        HStack(spacing: 6) { Glyph.add.view(16); Text("Add Domain") }
                    }
                    .buttonStyle(RouteButton(primary: true))
                }
            }
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
            .onExitCommand(perform: closeEditor)
        }
    }

    private func chip(_ address: String) -> some View {
        HStack(spacing: 5) {
            Text(address).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                .help(address)
            Button {
                model.removeAddress(address, from: list.addresses)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityLabel("Remove \(address)")
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(height: 31)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(line))
    }

    private func save() {
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try model.addAddresses(input, to: list.addresses)
            closeEditor()
        } catch {
            validationError = error.localizedDescription
            focused = true
        }
    }

    private func closeEditor() {
        editing = false
        input = ""
        validationError = nil
    }
}

private struct AddressFlow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? 342).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (view, item) in zip(subviews, arrangement.items) {
            view.place(at: CGPoint(x: bounds.minX + item.minX, y: bounds.minY + item.minY),
                       anchor: .topLeading, proposal: ProposedViewSize(item.size))
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (size: CGSize, items: [CGRect]) {
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var items: [CGRect] = []
        for view in subviews {
            var size = view.sizeThatFits(.unspecified)
            if size.width > width {
                size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
                size.width = width
            }
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            items.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), items)
    }
}
