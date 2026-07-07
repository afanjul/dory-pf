import Foundation
import Darwin

// dory-pf-proxy: user-space TCP proxy that replaces the old root/PF engine.
//
// Since macOS Mojave, a non-root process can bind a TCP port < 1024 as long
// as it binds the wildcard address (0.0.0.0 / ::). Binding a specific
// interface address on a low port still requires root. We exploit that: one
// dual-stack wildcard listener per configured rule, relaying to the real
// backend on 127.0.0.1. Non-loopback peers are rejected immediately after
// accept (no read, no data), so exposure from the wildcard bind is limited
// to "open a TCP connection and have it slammed shut."
//
// Runs as a user LaunchAgent (see daemon/local.dory-pf-proxy.plist). No PF,
// no root, no admin prompt.

// MARK: - Logging

let logQueue = DispatchQueue(label: "dory-pf-proxy.log")
let stdoutHandle = FileHandle.standardOutput

func log(_ message: String) {
    let formatter = logDateFormatter
    let timestamp = formatter.string(from: Date())
    let line = "\(timestamp) \(message)\n"
    logQueue.async {
        if let data = line.data(using: .utf8) {
            stdoutHandle.write(data)
        }
    }
}

let logDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

// MARK: - Config parsing

/// Parses ~/.dory/port-forwards.conf. Same rules as the GUI: blank lines and
/// lines starting with '#' are ignored, each remaining line is "FROM TO",
/// both integers in 1...65535. Later duplicate FROM entries override earlier
/// ones (last write wins), matching how a dictionary keyed by listen port
/// behaves.
func parseConfig(path: String) -> [Int: Int] {
    var rules: [Int: Int] = [:]
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        return rules
    }
    for rawLine in content.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("#") { continue }
        let parts = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard parts.count >= 2,
              let from = Int(parts[0]),
              let to = Int(parts[1]),
              from >= 1, from <= 65535,
              to >= 1, to <= 65535 else {
            log("config: ignoring invalid line: \(line)")
            continue
        }
        rules[from] = to
    }
    return rules
}

// MARK: - Loopback peer check

/// True if the given sockaddr_storage represents 127.0.0.1, ::1, or the
/// IPv4-mapped ::ffff:127.0.0.1 (how IPv4 peers show up on a dual-stack
/// AF_INET6 socket with IPV6_V6ONLY disabled).
func isLoopbackPeer(_ storage: sockaddr_storage) -> Bool {
    var storage = storage
    switch Int32(storage.ss_family) {
    case AF_INET:
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr -> Bool in
                let addr = ptr.pointee.sin_addr.s_addr
                // 127.0.0.1 in network byte order.
                return addr == inet_addr("127.0.0.1")
            }
        }
    case AF_INET6:
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ptr -> Bool in
                var addr = ptr.pointee.sin6_addr
                let isV6Loopback = withUnsafeBytes(of: &addr) { raw -> Bool in
                    var loopback = in6addr_loopback
                    return withUnsafeBytes(of: &loopback) { loopRaw in
                        raw.elementsEqual(loopRaw)
                    }
                }
                if isV6Loopback { return true }
                // Check for IPv4-mapped ::ffff:127.0.0.1
                let bytes = withUnsafeBytes(of: &addr) { Array($0) }
                guard bytes.count == 16 else { return false }
                let prefixIsZero = bytes[0..<10].allSatisfy { $0 == 0 }
                let mappedMarker = bytes[10] == 0xff && bytes[11] == 0xff
                let is127 = bytes[12] == 127 && bytes[13] == 0 && bytes[14] == 0 && bytes[15] == 1
                return prefixIsZero && mappedMarker && is127
            }
        }
    default:
        return false
    }
}

func describePeer(_ storage: sockaddr_storage) -> String {
    var storage = storage
    let addrLen = storage.ss_len == 0 ? socklen_t(MemoryLayout<sockaddr_storage>.size) : socklen_t(storage.ss_len)
    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let result = withUnsafePointer(to: &storage) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr -> Int32 in
            getnameinfo(sockPtr, addrLen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
        }
    }
    if result == 0 {
        return String(cString: host)
    }
    return "unknown"
}

// MARK: - Rejected peer rate limiting

final class RejectLogger {
    private let lock = NSLock()
    private var suppressedCount = 0
    private var lastLogged = Date.distantPast
    private let window: TimeInterval = 10.0

    func note(port: Int, peer: String) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(lastLogged) >= window {
            if suppressedCount > 0 {
                log("proxy: rejected non-loopback peer \(peer) on port \(port) (+\(suppressedCount) more suppressed in last \(Int(window))s)")
            } else {
                log("proxy: rejected non-loopback peer \(peer) on port \(port)")
            }
            lastLogged = now
            suppressedCount = 0
        } else {
            suppressedCount += 1
        }
    }
}

let rejectLogger = RejectLogger()

// MARK: - Connection relay

/// Pumps bytes from `src` to `dst` until EOF or error, then half-closes
/// `dst` for writing so the peer observes the natural end of stream.
func pump(from src: Int32, to dst: Int32, label: String, completion: @escaping () -> Void) {
    DispatchQueue.global(qos: .utility).async {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buffer.withUnsafeMutableBytes { raw -> Int in
                recv(src, raw.baseAddress, raw.count, 0)
            }
            if n <= 0 { break }
            var offset = 0
            var writeError = false
            while offset < n {
                let sent = buffer.withUnsafeBytes { raw -> Int in
                    send(dst, raw.baseAddress!.advanced(by: offset), n - offset, 0)
                }
                if sent <= 0 {
                    writeError = true
                    break
                }
                offset += sent
            }
            if writeError { break }
        }
        shutdown(dst, SHUT_WR)
        completion()
    }
}

func relay(clientFd: Int32, listenPort: Int, targetPort: Int) {
    let backendFd = socket(AF_INET, SOCK_STREAM, 0)
    guard backendFd >= 0 else {
        log("proxy: failed to create backend socket for rule \(listenPort)->\(targetPort): \(String(cString: strerror(errno)))")
        close(clientFd)
        return
    }

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(targetPort).bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let connected = connectWithTimeout(fd: backendFd, timeoutMillis: 2000) {
        withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(backendFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    guard connected else {
        log("proxy: backend connect failed for rule \(listenPort)->\(targetPort): \(String(cString: strerror(errno)))")
        close(backendFd)
        close(clientFd)
        return
    }

    let closeLock = NSLock()
    var closed = false
    func closeBoth() {
        closeLock.lock()
        if !closed {
            closed = true
            close(clientFd)
            close(backendFd)
        }
        closeLock.unlock()
    }

    let group = DispatchGroup()
    group.enter()
    pump(from: clientFd, to: backendFd, label: "client->backend") { group.leave() }
    group.enter()
    pump(from: backendFd, to: clientFd, label: "backend->client") { group.leave() }
    group.notify(queue: .global()) { closeBoth() }
}

/// Blocking connect with a timeout, borrowed from the same pattern used in
/// the GUI's target-port health check.
func connectWithTimeout(fd: Int32, timeoutMillis: Int32, _ connectCall: () -> Int32) -> Bool {
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

// MARK: - Listener management

struct ListenerState {
    var fd: Int32
    var source: DispatchSourceRead
    var targetPort: Int
}

final class ProxyServer {
    private let configPath: String
    private let stateQueue = DispatchQueue(label: "dory-pf-proxy.state")
    private var listeners: [Int: ListenerState] = [:]
    private var retryTimers: [Int: DispatchSourceTimer] = [:]
    private var desiredRules: [Int: Int] = [:]

    init(configPath: String) {
        self.configPath = configPath
    }

    func start() {
        stateQueue.async {
            let rules = parseConfig(path: self.configPath)
            self.logRuleSet(rules, context: "startup")
            self.applyRules(rules)
        }
        watchConfig()
    }

    private func logRuleSet(_ rules: [Int: Int], context: String) {
        if rules.isEmpty {
            log("proxy: \(context): no rules configured (\(configPath))")
        } else {
            let desc = rules.sorted { $0.key < $1.key }.map { "\($0.key)->\($0.value)" }.joined(separator: ", ")
            log("proxy: \(context): \(rules.count) rule(s): \(desc)")
        }
    }

    // Must be called on stateQueue.
    private func applyRules(_ rules: [Int: Int]) {
        desiredRules = rules

        // Remove listeners for rules that no longer exist. Established
        // connections already accepted keep running independently (they
        // hold their own fds), so this only stops accepting new ones.
        for port in listeners.keys where rules[port] == nil {
            closeListener(port: port)
        }
        cancelStaleRetries(rules)

        // Add or update listeners for current rules.
        for (port, target) in rules {
            if listeners[port] != nil {
                // Listener already open for this port; just repoint future
                // accepts at the new target. Existing connections on the
                // old target are left alone.
                listeners[port]?.targetPort = target
            } else {
                openListener(port: port, target: target)
            }
        }
    }

    private func cancelStaleRetries(_ rules: [Int: Int]) {
        for port in retryTimers.keys where rules[port] == nil {
            retryTimers[port]?.cancel()
            retryTimers.removeValue(forKey: port)
        }
    }

    // Must be called on stateQueue.
    private func closeListener(port: Int) {
        guard let state = listeners.removeValue(forKey: port) else { return }
        state.source.cancel()
        close(state.fd)
        log("proxy: closed listener on port \(port)")
    }

    // Must be called on stateQueue.
    private func openListener(port: Int, target: Int) {
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log("proxy: socket() failed for port \(port): \(String(cString: strerror(errno)))")
            scheduleRetry(port: port, target: target)
            return
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var v6only: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &v6only, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = UInt16(port).bigEndian
        addr.sin6_addr = in6addr_any

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindResult == 0 else {
            let savedErrno = errno
            close(fd)
            if savedErrno == EADDRINUSE {
                log("proxy: port \(port) busy (EADDRINUSE), will retry in 30s")
            } else {
                log("proxy: bind() failed for port \(port): \(String(cString: strerror(savedErrno)))")
            }
            scheduleRetry(port: port, target: target)
            return
        }

        guard listen(fd, SOMAXCONN) == 0 else {
            log("proxy: listen() failed for port \(port): \(String(cString: strerror(errno)))")
            close(fd)
            scheduleRetry(port: port, target: target)
            return
        }

        // Non-blocking so the accept loop can drain every pending
        // connection and return on EWOULDBLOCK/EAGAIN instead of blocking
        // the shared serial state queue on the final accept() call.
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: stateQueue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections(port: port, listenFd: fd)
        }
        source.setCancelHandler {
            // fd is closed explicitly by closeListener/openListener error paths.
        }
        source.resume()

        listeners[port] = ListenerState(fd: fd, source: source, targetPort: target)
        retryTimers[port]?.cancel()
        retryTimers.removeValue(forKey: port)
        log("proxy: listening on wildcard [::]:\(port) (dual-stack) -> 127.0.0.1:\(target)")
    }

    // Must be called on stateQueue.
    private func scheduleRetry(port: Int, target: Int) {
        retryTimers[port]?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.desiredRules[port] != nil, self.listeners[port] == nil else {
                timer.cancel()
                self.retryTimers.removeValue(forKey: port)
                return
            }
            let currentTarget = self.desiredRules[port] ?? target
            self.openListener(port: port, target: currentTarget)
        }
        timer.resume()
        retryTimers[port] = timer
    }

    // Must be called on stateQueue.
    private func acceptConnections(port: Int, listenFd: Int32) {
        while true {
            var storage = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let clientFd = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFd, $0, &len)
                }
            }
            if clientFd < 0 {
                // EWOULDBLOCK/EAGAIN just means no more pending connections.
                if errno != EWOULDBLOCK && errno != EAGAIN {
                    log("proxy: accept() error on port \(port): \(String(cString: strerror(errno)))")
                }
                return
            }
            // The accepted socket can inherit O_NONBLOCK from the (now
            // non-blocking) listening socket on this platform. relay()/pump()
            // are written for blocking I/O, so force it back off explicitly
            // rather than relying on accept() semantics.
            let clientFlags = fcntl(clientFd, F_GETFL, 0)
            if clientFlags >= 0 {
                _ = fcntl(clientFd, F_SETFL, clientFlags & ~O_NONBLOCK)
            }

            guard isLoopbackPeer(storage) else {
                rejectLogger.note(port: port, peer: describePeer(storage))
                close(clientFd)
                continue
            }

            guard let target = listeners[port]?.targetPort else {
                close(clientFd)
                continue
            }

            DispatchQueue.global(qos: .utility).async {
                relay(clientFd: clientFd, listenPort: port, targetPort: target)
            }
        }
    }

    // MARK: - Config watching

    private var dirWatchSource: DispatchSourceFileSystemObject?
    private var reloadWorkItem: DispatchWorkItem?

    private func watchConfig() {
        let dirPath = (configPath as NSString).deletingLastPathComponent
        // Make sure the directory exists so we have something to watch, and
        // future writes into it (including atomic replace via temp+rename)
        // generate events we can see.
        try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)

        let dirFd = open(dirPath, O_EVTONLY)
        guard dirFd >= 0 else {
            log("proxy: could not watch config directory \(dirPath): \(String(cString: strerror(errno)))")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: dirFd, eventMask: [.write, .rename, .delete], queue: stateQueue)
        source.setEventHandler { [weak self] in
            self?.debouncedReload()
        }
        source.setCancelHandler {
            close(dirFd)
        }
        source.resume()
        dirWatchSource = source

        // SIGHUP as a manual trigger.
        signal(SIGHUP, SIG_IGN)
        let hupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: stateQueue)
        hupSource.setEventHandler { [weak self] in
            log("proxy: SIGHUP received, reloading config")
            self?.reloadNow()
        }
        hupSource.resume()
        // Keep a reference so it is not deallocated.
        objc_setAssociatedObjectWorkaround.hupSource = hupSource

        // Defensive periodic poll in case a filesystem event is missed
        // (e.g. some editors/tools use write patterns that dodge kqueue
        // notifications on the containing directory).
        let pollTimer = DispatchSource.makeTimerSource(queue: stateQueue)
        pollTimer.schedule(deadline: .now() + 5, repeating: 5)
        pollTimer.setEventHandler { [weak self] in
            self?.reloadNow()
        }
        pollTimer.resume()
        objc_setAssociatedObjectWorkaround.pollTimer = pollTimer
    }

    // Must be called on stateQueue.
    private func debouncedReload() {
        reloadWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.reloadNow()
        }
        reloadWorkItem = work
        stateQueue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // Safe to call from stateQueue or async-scheduled onto it.
    private func reloadNow() {
        let rules = parseConfig(path: configPath)
        if rules != desiredRules {
            logRuleSet(rules, context: "reload")
            applyRules(rules)
        }
    }

    func shutdown() {
        stateQueue.sync {
            for port in listeners.keys {
                closeListener(port: port)
            }
            for (_, timer) in retryTimers {
                timer.cancel()
            }
            retryTimers.removeAll()
        }
    }
}

// Small helper to keep strong references to sources created inside a method
// without needing to declare more stored properties up front.
final class AssociatedSources {
    var hupSource: DispatchSourceSignal?
    var pollTimer: DispatchSourceTimer?
}
let objc_setAssociatedObjectWorkaround = AssociatedSources()

// MARK: - Entry point

signal(SIGPIPE, SIG_IGN)

let home = FileManager.default.homeDirectoryForCurrentUser.path
let configPath = home + "/.dory/port-forwards.conf"

log("proxy: dory-pf-proxy starting (pid \(getpid())), config: \(configPath)")

let server = ProxyServer(configPath: configPath)
server.start()

signal(SIGTERM, SIG_IGN)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: DispatchQueue.main)
sigtermSource.setEventHandler {
    log("proxy: SIGTERM received, shutting down")
    server.shutdown()
    exit(0)
}
sigtermSource.resume()

signal(SIGINT, SIG_IGN)
let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: DispatchQueue.main)
sigintSource.setEventHandler {
    log("proxy: SIGINT received, shutting down")
    server.shutdown()
    exit(0)
}
sigintSource.resume()

dispatchMain()
