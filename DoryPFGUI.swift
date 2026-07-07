import SwiftUI
import AppKit
import Foundation
import Darwin

struct PortForward: Identifiable, Hashable, Codable {
    var id = UUID()
    var fromPort: Int
    var toPort: Int
    
    private enum CodingKeys: String, CodingKey {
        case id, fromPort, toPort
    }
    
    init(id: UUID = UUID(), fromPort: Int, toPort: Int) {
        self.id = id
        self.fromPort = fromPort
        self.toPort = toPort
    }
    
    init(fromDecoder decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.fromPort = try container.decode(Int.self, forKey: .fromPort)
        self.toPort = try container.decode(Int.self, forKey: .toPort)
    }
}

struct Profile: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var forwards: [PortForward]
}

struct PortStatus: Hashable {
    var sourceOccupied: Bool = false
    var targetActive: Bool = false
    var occupyingProcessName: String? = nil
}

struct DockerSuggestion: Identifiable, Hashable {
    let id = UUID()
    var fromPort: Int
    var toPort: Int
    var containerName: String
}

struct DockerPort: Codable, Hashable {
    var IP: String?
    var PrivatePort: Int
    var PublicPort: Int?
    var `Type`: String
}

struct DockerContainer: Codable, Identifiable, Hashable {
    var id: String { Id }
    var Id: String
    var Names: [String]
    var Ports: [DockerPort]?
}

class PortForwardManager: ObservableObject {
    @Published var forwards: [PortForward] = []
    @Published var configPath: String = ""
    @Published var installError: String? = nil
    @Published var isProxyInstalled: Bool = false
    @Published var isProxyRunning: Bool = false

    @Published var profiles: [Profile] = []
    @Published var activeProfileId: UUID = UUID()
    @Published var portStatuses: [Int: PortStatus] = [:]
    @Published var dockerSuggestions: [DockerSuggestion] = []
    @Published var isCheckingStatuses: Bool = false
    
    private var checkTimer: Timer?
    private var statusCheckInFlight = false
    
    var configURL: URL {
        if !configPath.isEmpty {
            return URL(fileURLWithPath: (configPath as NSString).expandingTildeInPath)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".dory/port-forwards.conf")
    }
    
    init() {
        self.configPath = UserDefaults.standard.string(forKey: "configFilePath") ?? ""
        if self.configPath.isEmpty {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.configPath = home.appendingPathComponent(".dory/port-forwards.conf").path
        }
        
        loadProfiles()
        checkProxyStatus()
    }
    
    var launchAgentPlistPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.dory-pf-proxy.plist").path
    }

    var proxyLogPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/dory-pf-proxy.log").path
    }

    var proxyBinaryPath: String {
        Bundle.main.bundlePath + "/Contents/MacOS/dory-pf-proxy"
    }

    private var launchAgentLabel: String {
        "gui/\(getuid())/local.dory-pf-proxy"
    }

    @discardableResult
    private func runProcess(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.launchPath = path
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (task.terminationStatus, output)
        } catch {
            return (-1, error.localizedDescription)
        }
    }

    func checkProxyStatus() {
        let plistPath = launchAgentPlistPath
        let installed = FileManager.default.fileExists(atPath: plistPath)
        let label = launchAgentLabel
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            var running = false
            if installed {
                let (status, output) = self.runProcess("/bin/launchctl", ["print", label])
                running = status == 0 && output.contains("state = running")
            }
            DispatchQueue.main.async {
                self.isProxyInstalled = installed
                self.isProxyRunning = running
            }
        }
    }

    private func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private func validateConfigPath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return "Config path must be absolute." }
        guard !expanded.contains("\n"), !expanded.contains("\r"), !expanded.contains("\0") else {
            return "Config path cannot contain control characters."
        }
        return nil
    }
    
    func updateConfigPath(_ path: String) {
        if let validationError = validateConfigPath(path) {
            DispatchQueue.main.async {
                self.installError = validationError
            }
            return
        }
        UserDefaults.standard.set(path, forKey: "configFilePath")
        DispatchQueue.main.async {
            self.installError = nil
            self.configPath = path
            self.loadRules()
            self.performStatusChecks()
        }
    }
    
    func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: "profiles"),
           let decoded = try? JSONDecoder().decode([Profile].self, from: data),
           !decoded.isEmpty {
            self.profiles = decoded
            if let activeIdString = UserDefaults.standard.string(forKey: "activeProfileId"),
               let activeId = UUID(uuidString: activeIdString),
               decoded.contains(where: { $0.id == activeId }) {
                self.activeProfileId = activeId
            } else {
                self.activeProfileId = decoded[0].id
            }
            if let activeProfile = decoded.first(where: { $0.id == self.activeProfileId }) {
                self.forwards = activeProfile.forwards
            }
        } else {
            // Seed default profile from existing config file or empty
            var existingForwards: [PortForward] = []
            let url = configURL
            if FileManager.default.fileExists(atPath: url.path) {
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    let lines = content.components(separatedBy: .newlines)
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty || trimmed.hasPrefix("#") {
                            continue
                        }
                        let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                        if parts.count >= 2,
                           let from = Int(parts[0]),
                           let to = Int(parts[1]) {
                            existingForwards.append(PortForward(fromPort: from, toPort: to))
                        }
                    }
                } catch {
                    print("Error seeding: \(error)")
                }
            }
            
            let defaultProfile = Profile(name: "Default", forwards: existingForwards)
            self.profiles = [defaultProfile]
            self.activeProfileId = defaultProfile.id
            self.forwards = existingForwards
            saveProfilesToDefaults()
        }
    }
    
    func saveProfilesToDefaults() {
        if let encoded = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(encoded, forKey: "profiles")
        }
        UserDefaults.standard.set(activeProfileId.uuidString, forKey: "activeProfileId")
    }
    
    func selectProfile(id: UUID) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        self.activeProfileId = id
        self.forwards = profile.forwards
        saveProfilesToDefaults()
        saveRules()
        performStatusChecks()
    }
    
    func createProfile(name: String) {
        let newProfile = Profile(name: name, forwards: [])
        profiles.append(newProfile)
        selectProfile(id: newProfile.id)
    }
    
    func deleteProfile(id: UUID) {
        guard profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        
        if activeProfileId == id {
            let nextProfile = profiles[0]
            selectProfile(id: nextProfile.id)
        } else {
            saveProfilesToDefaults()
        }
    }
    
    func loadRules() {
        if let activeProfile = profiles.first(where: { $0.id == activeProfileId }) {
            self.forwards = activeProfile.forwards
        }
    }
    
    func saveRules() {
        var content = """
# ── dory-pf: low-port redirects (<1024) on localhost ─────────────────────────
# Format: one rule per line → "SOURCE_PORT TARGET_PORT"
# Saving this file is picked up automatically by the dory-pf-proxy LaunchAgent
# (it watches this file and hot-reloads within about a second).
# ──────────────────────────────────────────────────────────────────────────────

"""
        for forward in forwards {
            content += "\(forward.fromPort) \(forward.toPort)\n"
        }
        
        do {
            let dir = configURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            try content.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            print("Error saving config: \(error)")
        }
    }
    
    func add(from: Int, to: Int) {
        let newForward = PortForward(fromPort: from, toPort: to)
        forwards.append(newForward)
        
        if let idx = profiles.firstIndex(where: { $0.id == activeProfileId }) {
            profiles[idx].forwards = forwards
        }
        
        saveProfilesToDefaults()
        saveRules()
        performStatusChecks()
    }
    
    func delete(_ forward: PortForward) {
        forwards.removeAll { $0.id == forward.id }
        
        if let idx = profiles.firstIndex(where: { $0.id == activeProfileId }) {
            profiles[idx].forwards = forwards
        }
        
        saveProfilesToDefaults()
        saveRules()
        performStatusChecks()
    }
    
    func reload() {
        let url = configURL
        let now = Date()
        do {
            var attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            attributes[.modificationDate] = now
            try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
        } catch {
            saveRules()
        }
        performStatusChecks()
    }
    
    func startMonitoring() {
        checkTimer?.invalidate()
        performStatusChecks()
        checkTimer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.performStatusChecks()
        }
        if let checkTimer {
            RunLoop.main.add(checkTimer, forMode: .common)
        }
    }
    
    func stopMonitoring() {
        checkTimer?.invalidate()
        checkTimer = nil
    }
    
    func performStatusChecks() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.statusCheckInFlight else { return }
            self.statusCheckInFlight = true
            self.isCheckingStatuses = true
            let activeForwards = self.forwards
            DispatchQueue.global(qos: .background).async { [weak self] in
                self?.performStatusChecks(forwardsSnapshot: activeForwards)
            }
        }
    }
    
    private func performStatusChecks(forwardsSnapshot activeForwards: [PortForward]) {
        var newStatuses: [Int: PortStatus] = [:]
        
        for forward in activeForwards {
            // With the user-space proxy engine, the entry (low) port is a
            // real listening socket owned by our own proxy process, not a
            // kernel-level PF redirect. So "is something listening on the
            // entry port" is expected and healthy when it's our proxy; it's
            // only a genuine conflict when a *different* process holds it
            // (which also means our proxy failed to bind it).
            let entryPortListening = isTargetPortActive(forward.fromPort)
            let tgtActive = isTargetPortActive(forward.toPort)

            var processName: String? = nil
            var foreignConflict = false
            if entryPortListening {
                processName = getProcessOccupyingPort(forward.fromPort)
                let isOurProxy = processName?.lowercased().contains("dory-pf-proxy") ?? false
                foreignConflict = !isOurProxy
            }

            newStatuses[forward.fromPort] = PortStatus(
                sourceOccupied: foreignConflict,
                targetActive: tgtActive,
                occupyingProcessName: processName
            )
        }
        
        let suggestions = fetchDockerSuggestions(existingForwards: activeForwards)
        
        DispatchQueue.main.async {
            self.portStatuses = newStatuses
            self.dockerSuggestions = suggestions
            self.isCheckingStatuses = false
            self.statusCheckInFlight = false
        }
    }
    
    func findDockerSocket() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            "\(home)/.dory/dory.sock",
            "/var/run/docker.sock",
            "\(home)/.docker/run/docker.sock",
            "\(home)/.orbstack/run/docker.sock"
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    func queryDockerSocket(socketPath: String, path: String) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        
        var tv = timeval()
        tv.tv_sec = 1
        tv.tv_usec = 0
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        
        var addr = sockaddr_un()
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        addr.sun_family = sa_family_t(AF_UNIX)
        
        let pathLen = socketPath.utf8.count
        guard pathLen < 104 else { return nil }
        
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let rawPtr = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Int8.self)
            socketPath.withCString { cstr in
                rawPtr.update(from: cstr, count: pathLen + 1)
            }
        }
        
        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard connectResult == 0 else { return nil }
        
        let request = "GET \(path) HTTP/1.0\r\nHost: localhost\r\n\r\n"
        let sendResult = request.withCString { ptr in
            send(fd, ptr, strlen(ptr), 0)
        }
        guard sendResult >= 0 else { return nil }
        
        var responseData = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        
        while true {
            let bytesRead = recv(fd, buffer, bufferSize, 0)
            if bytesRead <= 0 {
                break
            }
            responseData.append(buffer, count: bytesRead)
        }
        
        guard let responseString = String(data: responseData, encoding: .utf8) else { return nil }
        
        guard responseString.hasPrefix("HTTP/1.0 200") || responseString.hasPrefix("HTTP/1.1 200") else {
            return nil
        }
        
        let parts = responseString.components(separatedBy: "\r\n\r\n")
        if parts.count >= 2 {
            return parts.dropFirst().joined(separator: "\r\n\r\n")
        }
        return nil
    }
    
    func fetchDockerSuggestions(existingForwards: [PortForward]) -> [DockerSuggestion] {
        guard let socketPath = findDockerSocket() else { return [] }
        guard let jsonString = queryDockerSocket(socketPath: socketPath, path: "/containers/json") else { return [] }
        guard let jsonData = jsonString.data(using: .utf8) else { return [] }
        
        do {
            let containers = try JSONDecoder().decode([DockerContainer].self, from: jsonData)
            var suggestions: [DockerSuggestion] = []
            
            for container in containers {
                guard let ports = container.Ports else { continue }
                let name = container.Names.first?.replacingOccurrences(of: "/", with: "") ?? "container"
                
                for port in ports {
                    guard port.`Type` == "tcp", let pub = port.PublicPort, pub > 0 && port.PrivatePort > 0 else { continue }
                    
                    var fromPort = port.PrivatePort
                    let toPort = pub
                    
                    if port.PrivatePort == 8080 || port.PrivatePort == 80 {
                        if toPort != 80 {
                            fromPort = 80
                        }
                    } else if port.PrivatePort == 8443 || port.PrivatePort == 443 {
                        if toPort != 443 {
                            fromPort = 443
                        }
                    }
                    
                    let alreadyExists = existingForwards.contains { $0.fromPort == fromPort && $0.toPort == toPort }
                    if !alreadyExists {
                        suggestions.append(DockerSuggestion(
                            fromPort: fromPort,
                            toPort: toPort,
                            containerName: name
                        ))
                    }
                }
            }
            return suggestions
        } catch {
            print("Error decoding Docker JSON: \(error)")
            return []
        }
    }
    
    func getProcessOccupyingPort(_ port: Int) -> String? {
        let task = Process()
        task.launchPath = "/usr/sbin/lsof"
        task.arguments = ["-b", "-i", "tcp:\(port)", "-sTCP:LISTEN", "-F", "c"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe() // Silence stderr warnings
        
        do {
            try task.run()
            task.waitUntilExit()
            
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let output = String(data: data, encoding: .utf8) {
                let lines = output.components(separatedBy: .newlines)
                for line in lines {
                    if line.hasPrefix("c") {
                        let procName = String(line.dropFirst())
                        return procName.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
            }
        } catch {
            print("Error running lsof: \(error)")
        }
        return nil
    }
    
    func isTargetPortActive(_ port: Int) -> Bool {
        guard port >= 1 && port <= 65535 else { return false }
        return isTargetPortActiveIPv4(port) || isTargetPortActiveIPv6(port)
    }
    
    private func setSocketTimeouts(_ fd: Int32) {
        var tv = timeval()
        tv.tv_sec = 0
        tv.tv_usec = 150000 // 150ms timeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }
    
    private func connectWithTimeout(fd: Int32, timeoutMillis: Int32 = 300, _ connectCall: () -> Int32) -> Bool {
        let originalFlags = fcntl(fd, F_GETFL, 0)
        if originalFlags >= 0 {
            _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
        }
        defer {
            if originalFlags >= 0 {
                _ = fcntl(fd, F_SETFL, originalFlags)
            }
        }
        
        let result = connectCall()
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        
        var pollFD = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollResult = poll(&pollFD, 1, timeoutMillis)
        guard pollResult > 0, (pollFD.revents & Int16(POLLOUT)) != 0 else { return false }
        
        var socketError: Int32 = 0
        var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &socketErrorLength) == 0 else { return false }
        return socketError == 0
    }
    
    private func isTargetPortActiveIPv4(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connectWithTimeout(fd: fd) {
                    connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }
    
    private func isTargetPortActiveIPv6(_ port: Int) -> Bool {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = UInt16(port).bigEndian
        addr.sin6_addr = in6addr_loopback
        
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connectWithTimeout(fd: fd) {
                    connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
    }
    
    /// Installs and starts the user-space proxy as a LaunchAgent. No admin
    /// prompt: everything happens in the user's own launchd domain.
    func installProxy() {
        if let validationError = validateConfigPath(configURL.path) {
            DispatchQueue.main.async {
                self.installError = validationError
            }
            return
        }

        let binaryPath = proxyBinaryPath
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            DispatchQueue.main.async {
                self.installError = "Proxy binary not found at \(binaryPath). Rebuild the app with build.sh."
            }
            return
        }

        let plistPath = launchAgentPlistPath
        let logPath = proxyLogPath
        let escapedBinaryPath = xmlEscaped(binaryPath)
        let escapedLogPath = xmlEscaped(logPath)

        let plistContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.dory-pf-proxy</string>
    <key>ProgramArguments</key>
    <array>
        <string>\(escapedBinaryPath)</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>StandardOutPath</key>
    <string>\(escapedLogPath)</string>
    <key>StandardErrorPath</key>
    <string>\(escapedLogPath)</string>
</dict>
</plist>
"""

        do {
            let agentsDir = (plistPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)
            let logsDir = (logPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
            try plistContent.write(toFile: plistPath, atomically: true, encoding: .utf8)

            // If already loaded (e.g. re-install), bootout first so bootstrap
            // doesn't fail with "already loaded".
            _ = runProcess("/bin/launchctl", ["bootout", launchAgentLabel])
            let (status, output) = runProcess("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath])

            if status != 0 {
                DispatchQueue.main.async {
                    self.installError = "launchctl bootstrap failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
            } else {
                _ = runProcess("/bin/launchctl", ["kickstart", "-k", launchAgentLabel])
                DispatchQueue.main.async {
                    self.installError = nil
                }
                saveRules()
            }
            checkProxyStatus()
        } catch {
            DispatchQueue.main.async {
                self.installError = error.localizedDescription
            }
        }
    }

    /// Stops the proxy and removes the LaunchAgent. No admin prompt.
    func uninstallProxy() {
        _ = runProcess("/bin/launchctl", ["bootout", launchAgentLabel])
        try? FileManager.default.removeItem(atPath: launchAgentPlistPath)
        DispatchQueue.main.async {
            self.installError = nil
        }
        checkProxyStatus()
    }

    /// Restarts the proxy service. Rule edits do not need this (the proxy
    /// hot-reloads its config file); it is the user-facing restart control
    /// for the service itself.
    func restartProxy() {
        let (status, output) = runProcess("/bin/launchctl", ["kickstart", "-k", launchAgentLabel])
        DispatchQueue.main.async {
            self.installError = status == 0 ? nil : "Restart failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
        checkProxyStatus()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

struct SettingsView: View {
    @ObservedObject var manager: PortForwardManager
    @Binding var showSettings: Bool
    @State private var tempPath: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: {
                    showSettings = false
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                }
                .buttonStyle(.borderless)
                
                Spacer()
                Text("Settings")
                    .font(.headline)
                Spacer()
                Spacer().frame(width: 50)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Config File Path")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    TextField("Path", text: $tempPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        manager.updateConfigPath(tempPath)
                    }
                }
            }
            .padding(.horizontal)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Proxy service")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack {
                    Image(systemName: statusIcon)
                        .foregroundColor(statusColor)
                        .font(.title3)
                    Text(statusText)
                        .font(.subheadline)
                    Spacer()
                }

                if manager.isProxyInstalled {
                    HStack(spacing: 12) {
                        Button(action: {
                            manager.restartProxy()
                        }) {
                            HStack {
                                Image(systemName: "arrow.clockwise")
                                Text("Restart Proxy")
                            }
                        }
                        .buttonStyle(.bordered)

                        Button(action: {
                            manager.uninstallProxy()
                        }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("Uninstall")
                            }
                            .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Button(action: {
                        manager.installProxy()
                    }) {
                        HStack {
                            Image(systemName: "bolt.fill")
                            Text("Install Proxy")
                        }
                    }
                    .buttonStyle(.bordered)
                }

                if let error = manager.installError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(.horizontal)

            Spacer()
        }
        .frame(width: 320, height: 360)
        .onAppear {
            tempPath = manager.configPath
        }
    }

    private var statusIcon: String {
        if !manager.isProxyInstalled { return "exclamationmark.triangle.fill" }
        return manager.isProxyRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var statusColor: Color {
        if !manager.isProxyInstalled { return .orange }
        return manager.isProxyRunning ? .green : .orange
    }

    private var statusText: String {
        if !manager.isProxyInstalled { return "Proxy not installed" }
        return manager.isProxyRunning ? "Proxy running" : "Proxy installed but not running"
    }
}

struct OnboardingView: View {
    @ObservedObject var manager: PortForwardManager
    @Binding var showSettings: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundColor(.yellow)
                    .font(.title)
                Text("Dory Port Forwarder")
                    .font(.title3)
                    .fontWeight(.bold)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 16)
            
            Text("A lightweight background proxy is required to redirect low ports (80, 443, ...) to your local services. It runs entirely in your user account — no admin password, no root, no system-level changes.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                Button(action: {
                    manager.installProxy()
                }) {
                    HStack {
                        Image(systemName: "bolt.fill")
                        Text("Install Proxy")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                
                if let error = manager.installError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                
                HStack {
                    Button("Settings") {
                        showSettings = true
                    }
                    Spacer()
                    Button("Quit") {
                        NSApp.terminate(nil)
                    }
                    .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
        .frame(width: 320, height: 360)
    }
}

struct ConflictInfoTooltip: View {
    let port: Int
    let processName: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Possible port conflict")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Local port \(port) is already bound")
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let processName, !processName.isEmpty {
                    Text("Detected process: \(processName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Text("Another process (not the Dory proxy) is holding this port, so the proxy cannot bind it and the forward will not work.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            
            Text("If this forward behaves unexpectedly, stop the conflicting service or use a different entry port.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 265, alignment: .leading)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 8)
        .allowsHitTesting(false)
    }
}

struct ContentView: View {
    @ObservedObject var manager: PortForwardManager
    @Binding var showSettings: Bool
    @Binding var fromPortStr: String
    @Binding var toPortStr: String
    
    @State private var showAddProfileCard = false
    @State private var newProfileName = ""
    @State private var hoveredConflictPort: Int? = nil
    
    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Image(systemName: "bolt.fill")
                    .foregroundColor(.yellow)
                    .font(.title2)
                Text("Dory PF")
                    .font(.headline)
                Spacer()
                Button(action: {
                    manager.reload()
                }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Reload rules & check ports")
                
                Button(action: {
                    showSettings = true
                }) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
                .help("Settings")
                
                Button(action: {
                    NSApp.terminate(nil)
                }) {
                    Image(systemName: "power")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
                .help("Quit App")
            }
            .padding(.horizontal)
            .padding(.top, 12)
            
            Divider()
            
            // Profile Selector Bar
            HStack(spacing: 8) {
                Text("Profile:")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Menu {
                    ForEach(manager.profiles) { p in
                        Button(action: {
                            manager.selectProfile(id: p.id)
                        }) {
                            HStack {
                                if manager.activeProfileId == p.id {
                                    Image(systemName: "checkmark")
                                }
                                Text(p.name)
                            }
                        }
                    }
                    Divider()
                    Button(action: {
                        showAddProfileCard = true
                    }) {
                        HStack {
                            Image(systemName: "plus")
                            Text("New Profile...")
                        }
                    }
                    if manager.profiles.count > 1 {
                        Button(role: .destructive, action: {
                            manager.deleteProfile(id: manager.activeProfileId)
                        }) {
                            HStack {
                                Image(systemName: "trash")
                                Text("Delete Profile")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(manager.profiles.first(where: { $0.id == manager.activeProfileId })?.name ?? "Default")
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
                }
                .menuStyle(.borderlessButton)
                
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 2)
            
            // Add Profile Card (Inline input)
            if showAddProfileCard {
                HStack(spacing: 8) {
                    TextField("Profile Name", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                    
                    Button("Save") {
                        if !newProfileName.isEmpty {
                            manager.createProfile(name: newProfileName)
                            newProfileName = ""
                            showAddProfileCard = false
                        }
                    }
                    
                    Button("Cancel") {
                        showAddProfileCard = false
                        newProfileName = ""
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(NSColor.alternatingContentBackgroundColors[0]))
                .cornerRadius(6)
                .padding(.horizontal)
            }
            
            // Rules List
            ScrollView {
                VStack(spacing: 8) {
                    if manager.forwards.isEmpty {
                        Text("No active forwards")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                            .padding(.vertical, 20)
                    } else {
                        ForEach(manager.forwards, id: \.self) { forward in
                            let status = manager.portStatuses[forward.fromPort]
                            let sourceOccupied = status?.sourceOccupied ?? false
                            let targetActive = status?.targetActive ?? false
                            let isKnown = status != nil
                            HStack(spacing: 6) {
                                // Conflict warning slot. Keep a fixed width even when hidden so
                                // all source/target ports stay vertically aligned across rows.
                                ZStack {
                                    if sourceOccupied {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.red)
                                            .contentShape(Rectangle())
                                            .onHover { isHovering in
                                                withAnimation(.easeInOut(duration: 0.12)) {
                                                    if isHovering {
                                                        hoveredConflictPort = forward.fromPort
                                                    } else if hoveredConflictPort == forward.fromPort {
                                                        hoveredConflictPort = nil
                                                    }
                                                }
                                            }
                                            .popover(
                                                isPresented: Binding(
                                                    get: { hoveredConflictPort == forward.fromPort },
                                                    set: { isPresented in
                                                        if !isPresented, hoveredConflictPort == forward.fromPort {
                                                            hoveredConflictPort = nil
                                                        }
                                                    }
                                                ),
                                                attachmentAnchor: .rect(.bounds),
                                                arrowEdge: .leading
                                            ) {
                                                ConflictInfoTooltip(
                                                    port: forward.fromPort,
                                                    processName: status?.occupyingProcessName
                                                )
                                                .padding(4)
                                            }
                                    }
                                }
                                .frame(width: 22, alignment: .center)
                                
                                Text(String(forward.fromPort))
                                    .fontWeight(.bold)
                                    .frame(width: 50, alignment: .trailing)
                                
                                Image(systemName: "arrow.right")
                                    .foregroundColor(.secondary)
                                
                                Text(String(forward.toPort))
                                    .fontWeight(.bold)
                                    .frame(width: 50, alignment: .leading)
                                
                                Spacer()
                                
                                // Destination port check
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(isKnown ? (targetActive ? Color.green : Color.gray) : Color.orange)
                                        .frame(width: 8, height: 8)
                                    Text(isKnown ? (targetActive ? "active" : "inactive") : "checking…")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .help(!isKnown ? "Checking forward status…" : (targetActive ? "Backend is reachable on target port \(forward.toPort)." : "No reachable listener detected on target port \(forward.toPort). Verify your service/container is running."))
                                
                                Spacer().frame(width: 10)
                                
                                Button(action: {
                                    manager.delete(forward)
                                }) {
                                    Image(systemName: "trash")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color(NSColor.alternatingContentBackgroundColors[0]))
                            .cornerRadius(6)
                            .zIndex(hoveredConflictPort == forward.fromPort ? 50 : 0)
                        }
                    }
                }
                .padding(.horizontal)
            }
            .frame(height: manager.dockerSuggestions.isEmpty ? 150 : 110)
            
            // Docker Suggestions
            if !manager.dockerSuggestions.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("Suggested Forwards (Docker)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(manager.dockerSuggestions) { suggestion in
                                Button(action: {
                                    manager.add(from: suggestion.fromPort, to: suggestion.toPort)
                                }) {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundColor(.green)
                                        Text("\(String(suggestion.fromPort))➔\(String(suggestion.toPort))")
                                            .fontWeight(.semibold)
                                        Text("(\(suggestion.containerName))")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: 26)
                }
            }
            
            Divider()
            
            // Add New Rule Form
            VStack(spacing: 6) {
                HStack {
                    Text("Add Forward")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                
                HStack(spacing: 8) {
                    TextField("From", text: $fromPortStr)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Image(systemName: "arrow.right")
                        .foregroundColor(.secondary)
                    TextField("To", text: $toPortStr)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    
                    Button(action: {
                        if let from = Int(fromPortStr), let to = Int(toPortStr) {
                            manager.add(from: from, to: to)
                            fromPortStr = ""
                            toPortStr = ""
                        }
                    }) {
                        Text("Add")
                    }
                    .disabled(
                        Int(fromPortStr) == nil || 
                        Int(toPortStr) == nil || 
                        (Int(fromPortStr) ?? 0) < 1 || 
                        (Int(fromPortStr) ?? 0) > 65535 || 
                        (Int(toPortStr) ?? 0) < 1 || 
                        (Int(toPortStr) ?? 0) > 65535
                    )
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 12)
        }
        .frame(width: 320, height: 360)
        .onAppear {
            manager.performStatusChecks()
        }
        .onChange(of: manager.forwards) {
            manager.performStatusChecks()
        }
    }
}

struct MainView: View {
    @ObservedObject var manager: PortForwardManager
    @State private var fromPortStr = ""
    @State private var toPortStr = ""
    @State private var showSettings = false
    
    var body: some View {
        Group {
            if showSettings {
                SettingsView(manager: manager, showSettings: $showSettings)
            } else if !manager.isProxyInstalled {
                OnboardingView(manager: manager, showSettings: $showSettings)
            } else {
                ContentView(manager: manager, showSettings: $showSettings, fromPortStr: $fromPortStr, toPortStr: $toPortStr)
            }
        }
        .onAppear {
            manager.startMonitoring()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            manager.startMonitoring()
        }
        .onDisappear {
            manager.stopMonitoring()
        }
    }
}

@main
struct DoryPFApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var manager = PortForwardManager()
    
    var body: some Scene {
        MenuBarExtra {
            MainView(manager: manager)
        } label: {
            Image(systemName: "bolt.horizontal.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
