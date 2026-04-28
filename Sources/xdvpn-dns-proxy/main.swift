import Darwin
import Foundation

// MARK: - Signal handling

var terminated: sig_atomic_t = 0
signal(SIGTERM) { _ in terminated = 1 }
signal(SIGINT) { _ in terminated = 1 }

// MARK: - Argument parsing

func parseArgs() -> (vpnDNS: String, utun: String, domainsPath: String) {
    let args = CommandLine.arguments
    var vpnDNS: String?
    var utun: String?
    var domainsPath: String?
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--vpn-dns" where i + 1 < args.count:
            vpnDNS = args[i + 1]; i += 2
        case "--utun" where i + 1 < args.count:
            utun = args[i + 1]; i += 2
        case "--domains" where i + 1 < args.count:
            domainsPath = args[i + 1]; i += 2
        default:
            fputs("Unknown argument: \(args[i])\n", stderr); exit(1)
        }
    }
    guard let dns = vpnDNS, let tun = utun, let path = domainsPath else {
        fputs("Usage: xdvpn-dns-proxy --vpn-dns <ip> --utun <dev> --domains <path>\n", stderr)
        exit(1)
    }
    return (dns, tun, path)
}

// MARK: - Domain loading

func loadDomains(from path: String) -> [String] {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("Failed to read domains file: \(path)\n", stderr)
        exit(1)
    }
    return content
        .components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
}

// MARK: - Resolver file management

func createResolverFiles(for suffixes: [String]) {
    let fm = FileManager.default
    let dir = "/etc/resolver"
    if !fm.fileExists(atPath: dir) {
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    }
    for suffix in suffixes {
        let path = "\(dir)/\(suffix)"
        try? "nameserver 127.0.0.1\n".write(toFile: path, atomically: true, encoding: .utf8)
    }
}

func deleteResolverFiles(for suffixes: [String]) {
    let fm = FileManager.default
    for suffix in suffixes {
        try? fm.removeItem(atPath: "/etc/resolver/\(suffix)")
    }
}

// MARK: - Health check

func utunExists(_ name: String) -> Bool {
    return if_nametoindex(name) != 0
}

// MARK: - Route management

func addRoute(host ip: String, interface utun: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/sbin/route")
    proc.arguments = ["add", "-host", ip, "-interface", utun]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
    proc.waitUntilExit()
}

// MARK: - DNS parsing

func extractARecordIPs(from buf: UnsafePointer<UInt8>, length: Int) -> [String] {
    guard length >= 12 else { return [] }

    let qdcount = (Int(buf[4]) << 8) | Int(buf[5])
    let ancount = (Int(buf[6]) << 8) | Int(buf[7])
    guard ancount > 0 else { return [] }

    var offset = 12

    // Skip question section
    for _ in 0..<qdcount {
        guard offset < length else { return [] }
        offset = skipName(buf, length: length, offset: offset)
        guard offset >= 0 else { return [] }
        offset += 4 // QTYPE + QCLASS
        guard offset <= length else { return [] }
    }

    var ips: [String] = []

    for _ in 0..<ancount {
        guard offset < length else { break }
        offset = skipName(buf, length: length, offset: offset)
        guard offset >= 0, offset + 10 <= length else { break }

        let rtype = (Int(buf[offset]) << 8) | Int(buf[offset + 1])
        let rdlength = (Int(buf[offset + 8]) << 8) | Int(buf[offset + 9])
        offset += 10
        guard offset + rdlength <= length else { break }

        if rtype == 1, rdlength == 4 {
            let ip = "\(buf[offset]).\(buf[offset+1]).\(buf[offset+2]).\(buf[offset+3])"
            ips.append(ip)
        }
        offset += rdlength
    }

    return ips
}

func skipName(_ buf: UnsafePointer<UInt8>, length: Int, offset: Int) -> Int {
    var pos = offset
    while pos < length {
        let b = buf[pos]
        if b == 0 {
            return pos + 1
        }
        if b & 0xC0 == 0xC0 {
            return pos + 2
        }
        pos += Int(b) + 1
    }
    return -1
}

// MARK: - SERVFAIL response

func buildServfail(from query: UnsafePointer<UInt8>, queryLen: Int) -> [UInt8] {
    guard queryLen >= 12 else { return [] }

    var resp = [UInt8]()
    resp.append(query[0])
    resp.append(query[1])
    resp.append(0x81) // response, recursion desired
    resp.append(0x82) // recursion available, SERVFAIL
    resp.append(query[4]) // QDCOUNT
    resp.append(query[5])
    resp.append(0); resp.append(0) // ANCOUNT
    resp.append(0); resp.append(0) // NSCOUNT
    resp.append(0); resp.append(0) // ARCOUNT

    // Copy question section
    var offset = 12
    let qdcount = (Int(query[4]) << 8) | Int(query[5])
    for _ in 0..<qdcount {
        guard offset < queryLen else { break }
        let nameEnd = skipName(query, length: queryLen, offset: offset)
        guard nameEnd >= 0, nameEnd + 4 <= queryLen else { break }
        for i in offset..<(nameEnd + 4) {
            resp.append(query[i])
        }
        offset = nameEnd + 4
    }

    return resp
}

// MARK: - Socket helpers

func createBoundListener() -> Int32 {
    let sock = socket(AF_INET, SOCK_DGRAM, 0)
    guard sock >= 0 else {
        fputs("Failed to create socket: \(String(cString: strerror(errno)))\n", stderr)
        exit(1)
    }

    var reuse: Int32 = 1
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(53).bigEndian
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else {
        fputs("Failed to bind 127.0.0.1:53: \(String(cString: strerror(errno)))\n", stderr)
        close(sock)
        exit(1)
    }
    return sock
}

func createUpstreamSocket(vpnDNS: String) -> (Int32, sockaddr_in) {
    let sock = socket(AF_INET, SOCK_DGRAM, 0)
    guard sock >= 0 else {
        fputs("Failed to create upstream socket: \(String(cString: strerror(errno)))\n", stderr)
        exit(1)
    }

    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var upstream = sockaddr_in()
    upstream.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    upstream.sin_family = sa_family_t(AF_INET)
    upstream.sin_port = UInt16(53).bigEndian
    upstream.sin_addr = in_addr(s_addr: inet_addr(vpnDNS))

    return (sock, upstream)
}

// MARK: - Main

let config = parseArgs()
let suffixes = loadDomains(from: config.domainsPath)

guard !suffixes.isEmpty else {
    fputs("No domain suffixes found in \(config.domainsPath)\n", stderr)
    exit(1)
}

createResolverFiles(for: suffixes)

let listenerSock = createBoundListener()
let (upstreamSock, upstreamAddr) = createUpstreamSocket(vpnDNS: config.vpnDNS)

var routeCache = Set<String>()
var recvBuf = [UInt8](repeating: 0, count: 65535)

func cleanup() {
    deleteResolverFiles(for: suffixes)
    close(listenerSock)
    close(upstreamSock)
}

// Main loop
while terminated == 0 {
    var pfd = pollfd(fd: listenerSock, events: Int16(POLLIN), revents: 0)
    let pollResult = poll(&pfd, 1, 3000)

    if terminated != 0 { break }

    if pollResult > 0, pfd.revents & Int16(POLLIN) != 0 {
        var clientAddr = sockaddr_in()
        var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let queryLen = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                recvfrom(listenerSock, &recvBuf, recvBuf.count, 0, sa, &clientLen)
            }
        }
        guard queryLen > 0 else { continue }

        // Forward query to VPN DNS
        var upstream = upstreamAddr
        let sendLen = withUnsafePointer(to: &upstream) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(upstreamSock, &recvBuf, queryLen, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        var responseBuf = [UInt8](repeating: 0, count: 65535)
        var responseLen: Int = -1

        if sendLen > 0 {
            responseLen = recv(upstreamSock, &responseBuf, responseBuf.count, 0)
        }

        if responseLen > 0 {
            let ips = responseBuf.withUnsafeBufferPointer { ptr in
                extractARecordIPs(from: ptr.baseAddress!, length: responseLen)
            }
            for ip in ips {
                if !routeCache.contains(ip) {
                    routeCache.insert(ip)
                    addRoute(host: ip, interface: config.utun)
                }
            }

            withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(listenerSock, &responseBuf, responseLen, 0, sa, clientLen)
                }
            }
        } else {
            var servfail = recvBuf.withUnsafeBufferPointer { ptr in
                buildServfail(from: ptr.baseAddress!, queryLen: queryLen)
            }
            guard !servfail.isEmpty else { continue }

            withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(listenerSock, &servfail, servfail.count, 0, sa, clientLen)
                }
            }
        }
    } else if pollResult == 0 {
        if !utunExists(config.utun) {
            cleanup()
            exit(0)
        }
    }
}

cleanup()
exit(0)
