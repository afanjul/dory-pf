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
    @Published var isDaemonInstalled: Bool = false
    
    @Published var profiles: [Profile] = []
    @Published var activeProfileId: UUID = UUID()
    @Published var portStatuses: [Int: PortStatus] = [:]
    @Published var dockerSuggestions: [DockerSuggestion] = []
    
    private var checkTimer: Timer?
    
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
        checkDaemonStatus()
    }
    
    func checkDaemonStatus() {
        let plistPath = "/Library/LaunchDaemons/local.dory-pf.plist"
        let scriptPath = "/usr/local/libexec/dory-pf.sh"
        let installed = FileManager.default.fileExists(atPath: plistPath) && FileManager.default.fileExists(atPath: scriptPath)
        DispatchQueue.main.async {
            self.isDaemonInstalled = installed
        }
    }
    
    func updateConfigPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: "configFilePath")
        DispatchQueue.main.async {
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
# ── dory-pf: redirecciones de puertos bajos (<1024) en localhost ─────────────
# Formato: una línea por regla → "PUERTO_ORIGEN PUERTO_DESTINO"
# Al guardar este archivo las reglas se aplican solas (LaunchDaemon con WatchPaths).
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
        checkTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.performStatusChecks()
        }
        DispatchQueue.global(qos: .background).async { [weak self] in
            self?.performStatusChecks()
        }
    }
    
    func stopMonitoring() {
        checkTimer?.invalidate()
        checkTimer = nil
    }
    
    func performStatusChecks() {
        let activeForwards = self.forwards
        var newStatuses: [Int: PortStatus] = [:]
        
        for forward in activeForwards {
            let srcOccupied = isSourcePortOccupied(forward.fromPort)
            let tgtActive = isTargetPortActive(forward.toPort)
            
            var processName: String? = nil
            if srcOccupied {
                processName = getProcessOccupyingPort(forward.fromPort)
            }
            
            newStatuses[forward.fromPort] = PortStatus(
                sourceOccupied: srcOccupied,
                targetActive: tgtActive,
                occupyingProcessName: processName
            )
        }
        
        let suggestions = fetchDockerSuggestions()
        
        DispatchQueue.main.async {
            self.portStatuses = newStatuses
            self.dockerSuggestions = suggestions
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
        
        let parts = responseString.components(separatedBy: "\r\n\r\n")
        if parts.count >= 2 {
            return parts[1]
        }
        return nil
    }
    
    func fetchDockerSuggestions() -> [DockerSuggestion] {
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
                    
                    let alreadyExists = self.forwards.contains { $0.fromPort == fromPort && $0.toPort == toPort }
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
    
    func isSourcePortOccupied(_ port: Int) -> Bool {
        guard port >= 1 && port <= 65535 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result < 0 && errno == EADDRINUSE
    }
    
    func isTargetPortActive(_ port: Int) -> Bool {
        guard port >= 1 && port <= 65535 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        
        var tv = timeval()
        tv.tv_sec = 0
        tv.tv_usec = 150000 // 150ms timeout
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
    
    func installDaemon() {
        let tempScriptPath = "/tmp/dory-pf.sh"
        let tempPlistPath = "/tmp/local.dory-pf.plist"
        
        let plistContent = """
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.dory-pf</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/libexec/dory-pf.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>WatchPaths</key>
    <array>
        <string>\(configURL.path)</string>
    </array>
    <key>StandardErrorPath</key>
    <string>/var/log/dory-pf.log</string>
    <key>StandardOutPath</key>
    <string>/var/log/dory-pf.log</string>
</dict>
</plist>
"""
        
        let scriptContent = """
#!/bin/sh
CONF="\(configURL.path)"
ANCHOR="com.dory.rdr"
rules=""
if [ -f "$CONF" ]; then
  while read -r from to _; do
    case "$from" in ""|\\#*) continue ;; esac
    [ -n "$to" ] || continue
    case "$from$to" in *[!0-9]*) echo "dory-pf: linea invalida ignorada: $from $to" >&2; continue ;; esac
    if [ "$from" -ge 1 ] && [ "$from" -le 65535 ] && [ "$to" -ge 1 ] && [ "$to" -le 65535 ]; then
      rules="${rules}rdr pass on lo0 inet proto tcp from any to 127.0.0.1 port = $from -> 127.0.0.1 port $to
rdr pass on lo0 inet6 proto tcp from any to ::1 port = $from -> ::1 port $to
"
    fi
  done < "$CONF"
fi
/sbin/pfctl -E 2>/dev/null || true
printf '%s' "$rules" | /sbin/pfctl -a "$ANCHOR" -f -
"""
        
        do {
            try plistContent.write(toFile: tempPlistPath, atomically: true, encoding: .utf8)
            try scriptContent.write(toFile: tempScriptPath, atomically: true, encoding: .utf8)
            
            let bashCmd = """
mkdir -p /usr/local/libexec && \
cp \(tempScriptPath) /usr/local/libexec/dory-pf.sh && \
chmod +x /usr/local/libexec/dory-pf.sh && \
cp \(tempPlistPath) /Library/LaunchDaemons/local.dory-pf.plist && \
if ! grep -q 'rdr-anchor "com.dory.rdr"' /etc/pf.conf; then \
  perl -pi -e 's/rdr-anchor "com.apple\\\\\\/\\\\\\*"/rdr-anchor "com.apple\\\\\\/\\\\\\*"\n# dory-pf: reglas cargadas por \\/usr\\/local\\/libexec\\/dory-pf.sh\nrdr-anchor "com.dory.rdr"/g' /etc/pf.conf; \
fi && \
launchctl load -w /Library/LaunchDaemons/local.dory-pf.plist && \
pfctl -f /etc/pf.conf
"""
            
            let appleScriptSource = "do shell script \"\(bashCmd)\" with administrator privileges"
            let appleScript = NSAppleScript(source: appleScriptSource)
            var errorInfo: NSDictionary?
            appleScript?.executeAndReturnError(&errorInfo)
            
            if let error = errorInfo {
                DispatchQueue.main.async {
                    self.installError = error["NSAppleScriptErrorMessage"] as? String ?? "Authorization failed"
                }
            } else {
                DispatchQueue.main.async {
                    self.installError = nil
                }
                try? FileManager.default.removeItem(atPath: tempScriptPath)
                try? FileManager.default.removeItem(atPath: tempPlistPath)
                checkDaemonStatus()
                saveRules()
            }
        } catch {
            DispatchQueue.main.async {
                self.installError = error.localizedDescription
            }
        }
    }
    
    func uninstallDaemon() {
        let bashCmd = """
launchctl unload -w /Library/LaunchDaemons/local.dory-pf.plist 2>/dev/null || true && \
rm -f /Library/LaunchDaemons/local.dory-pf.plist /usr/local/libexec/dory-pf.sh && \
perl -pi -e 's/# dory-pf: reglas cargadas por \\/usr\\/local\\/libexec\\/dory-pf.sh\nrdr-anchor "com.dory.rdr"\n//g' /etc/pf.conf && \
pfctl -f /etc/pf.conf
"""
        let appleScript = NSAppleScript(source: "do shell script \"\(bashCmd)\" with administrator privileges")
        var errorInfo: NSDictionary?
        appleScript?.executeAndReturnError(&errorInfo)
        
        if let error = errorInfo {
            DispatchQueue.main.async {
                self.installError = error["NSAppleScriptErrorMessage"] as? String ?? "Authorization failed"
            }
        } else {
            DispatchQueue.main.async {
                self.installError = nil
            }
            checkDaemonStatus()
        }
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
                Text("LaunchDaemon helper")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                HStack {
                    Image(systemName: manager.isDaemonInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(manager.isDaemonInstalled ? .green : .orange)
                        .font(.title3)
                    Text(manager.isDaemonInstalled ? "Daemon active" : "Daemon not active")
                        .font(.subheadline)
                    Spacer()
                }
                
                if manager.isDaemonInstalled {
                    Button(action: {
                        manager.uninstallDaemon()
                    }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Uninstall Helper Daemon")
                        }
                        .foregroundColor(.red)
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button(action: {
                        manager.installDaemon()
                    }) {
                        HStack {
                            Image(systemName: "shield.fill")
                            Text("Install Helper Daemon")
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
            
            Text("A system helper daemon is required to inject redirection rules into the macOS kernel Packet Filter (PF) as root.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .padding(.horizontal)
            
            Spacer()
            
            VStack(spacing: 12) {
                Button(action: {
                    manager.installDaemon()
                }) {
                    HStack {
                        Image(systemName: "shield.fill")
                        Text("Install LaunchDaemon")
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

struct ContentView: View {
    @ObservedObject var manager: PortForwardManager
    @Binding var showSettings: Bool
    @Binding var fromPortStr: String
    @Binding var toPortStr: String
    
    @State private var showAddProfileCard = false
    @State private var newProfileName = ""
    
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
                            let status = manager.portStatuses[forward.fromPort] ?? PortStatus()
                            HStack(spacing: 6) {
                                // Conflict Warning
                                if status.sourceOccupied {
                                    let processLabel = status.occupyingProcessName.map { " (occupied by \($0))" } ?? ""
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.red)
                                        .help("Conflict: Local port \(forward.fromPort) is bound by another application\(processLabel)!")
                                }
                                
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
                                        .fill(status.targetActive ? Color.green : Color.gray)
                                        .frame(width: 8, height: 8)
                                    Text(status.targetActive ? "active" : "inactive")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .help(status.targetActive ? "Target container port \(forward.toPort) is listening." : "No listening process detected on target port \(forward.toPort). Verify if your container is running.")
                                
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
            } else if !manager.isDaemonInstalled {
                OnboardingView(manager: manager, showSettings: $showSettings)
            } else {
                ContentView(manager: manager, showSettings: $showSettings, fromPortStr: $fromPortStr, toPortStr: $toPortStr)
            }
        }
        .onAppear {
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
