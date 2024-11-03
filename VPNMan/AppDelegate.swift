import Cocoa
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: – UI

    var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let launchAtLoginItem: NSMenuItem = .init(
        title: "Launch at Login",
        action: #selector(launchAtLogin(_:)),
        keyEquivalent: ""
    )

    // MARK: – Properties

    private let vpnConfigs = CurrentValueSubject<[VPNConfiguration], Never>([])
    private var cancellables: Set<AnyCancellable> = []

    private let launchAtLoginKey = "launchAtLogin"
    private var launchAtLogin: Bool = false

    // MARK: – Life Cycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        bind()
        loadVpnConfigs()

        launchAtLogin = UserDefaults.standard.bool(forKey: launchAtLoginKey)
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.set(launchAtLogin, forKey: launchAtLoginKey)
    }

    private func bind() {
        vpnConfigs.sink { configs in
            Task { @MainActor in
                self.setupTray(from: configs)
            }
        }
        .store(in: &cancellables)
    }

    // MARK: – Setup UI

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "circle", accessibilityDescription: "Tray Icon")
        launchAtLoginItem.state = UserDefaults.standard.bool(forKey: launchAtLoginKey) ? .on : .off

        menu.addItem(NSMenuItem.separator())
        menu.addItem(launchAtLoginItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem?.menu = menu
    }

    @MainActor
    private func setupTray(from configs: [VPNConfiguration]) {
        if configs.first(where: { $0.isConnected }) != nil {
            Task { await changeIcon(toOn: true) }
        }

        for vpnConfig in configs {
            let menuItem = NSMenuItem()
            menuItem.title = vpnConfig.name
            menuItem.state = vpnConfig.isConnected ? .on : .off
            menuItem.action = #selector(vpnMenuItemTapped(_:))
            menuItem.isEnabled = true
            menuItem.target = self
            menuItem.representedObject = vpnConfig
            menu.insertItem(menuItem, at: 0)
        }
    }

    private func changeIcon(toOn: Bool) async {
        await Task { @MainActor in
            statusItem?.button?.image = NSImage(
                systemSymbolName: toOn ? "circle.fill" : "circle",
                accessibilityDescription: ""
            )
        }.value
    }

    // TODO: loadConfigs from this, maybe need NSMenuDelegate
    @objc
    private func vpnMenuTapped() { }

    @objc
    private func vpnMenuItemTapped(_ sender: NSMenuItem) {
        guard var vpnConfig = sender.representedObject as? VPNConfiguration else { return }

        Task {
            do {
                try await runCommand(
                    vpnConfig.isConnected ? .stop(vpnConfig.name) : .start(vpnConfig.name)
                )

                vpnConfig.isConnected.toggle()
                await changeIcon(toOn: vpnConfig.isConnected)
                sender.state = vpnConfig.isConnected ? .on : .off

                sender.representedObject = vpnConfig
            } catch {
                alertError(error)
            }
        }
    }

    @objc
    private func launchAtLogin(_ sender: NSMenuItem) {
        launchAtLogin.toggle()
        launchAtLogin(enable: launchAtLogin)
        launchAtLoginItem.state = launchAtLogin ? .on : .off
    }

    private func loadVpnConfigs() {
        Task { @MainActor in
            do {
                let commandResult = try await runCommand(.list)

                let vpnConfigsData: [String] = commandResult
                    .split(separator: "\n")
                    .filter { $0.lowercased().contains("vpn") }
                    .map { String($0) }

                vpnConfigs.send(try parseVPNData(vpnConfigsData))
            } catch {
                alertError(error)
            }
        }
    }

    private func parseVPNData(_ data: [String]) throws -> [VPNConfiguration] {
        try data.compactMap { vpnInString in
            let vpnParams = vpnInString
                .split(separator: " ")
                .map { String($0) }

            guard vpnParams.count >= 6 else {
                throw FormatError.invalidFormat("Invalid VPN configuration: \(vpnInString)")
            }

            let isConnected = vpnParams[1] == "(Connected)"
            let uuid = vpnParams[2]
            let serviceType = vpnParams[3]
            let name = vpnParams[5]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

            return VPNConfiguration(
                id: uuid,
                name: name,
                isConnected: isConnected,
                serviceType: serviceType
            )
        }
    }

    // MARK: – System

    @discardableResult
    private func runCommand(_ command: Command) async throws -> String {
        try await Task {
            let process = Process()
            process.launchPath = "/bin/zsh"
            process.arguments = ["-c", command.body]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            process.launch()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            guard let output = String(data: data, encoding: .utf8) else {
                throw CommandError.executionFailed("Failed to parse output")
            }

            if process.terminationStatus != 0 {
                throw CommandError.executionFailed(output)
            }

            return output
        }.value
    }

    private func alertError(_ error: Error, additionInfo: String? = nil) {
        let alert = NSAlert()

        alert.messageText = error.localizedDescription
        if let additionInfo {
            alert.informativeText = additionInfo
        }

        let _ = alert.runModal()
    }

    private func launchAtLogin(enable: Bool) {
        do {
            if #available(macOS 13.0, *) {
                if enable {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            alertError(error, additionInfo: "Failed to register or unregister for launch at login")
        }
    }
}
