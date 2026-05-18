#if DEBUG
import AppKit
import ApplicationServices
import Foundation
import Network

final class DebugServer {
    private var listener: NWListener?
    private let port: UInt16 = 19876
    private weak var vpn: VPNController?
    private weak var updater: UpdateChecker?

    init(vpn: VPNController, updater: UpdateChecker) {
        self.vpn = vpn
        self.updater = updater
    }

    func start() {
        print("[DebugServer] start() called")
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let nwPort = NWEndpoint.Port(rawValue: port),
              let l = try? NWListener(using: params, on: nwPort) else {
            print("[DebugServer] cannot bind :\(port)")
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.stateUpdateHandler = { [port] st in
            print("[DebugServer] state: \(st)")
            if case .ready = st { print("[DebugServer] ready on localhost:\(port)") }
        }
        l.start(queue: .global(qos: .utility))
        print("[DebugServer] listener started")
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .global(qos: .utility))
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let raw = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            Task { @MainActor in
                let (code, body) = self.route(raw)
                let header = "HTTP/1.1 \(code)\r\nContent-Type: application/json; charset=utf-8\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
                conn.send(content: (header + body).data(using: .utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    // MARK: - Routing

    @MainActor
    private func route(_ raw: String) -> (String, String) {
        let req = Self.parseHTTP(raw)
        switch (req.method, req.path) {
        case ("GET", "/health"):
            return Self.ok(["ok": true, "pid": getpid()])
        case ("GET", "/state"):
            return Self.ok(buildState())
        case ("GET", "/ax"):
            let depth = Int(req.query["depth"] ?? "") ?? 15
            return Self.ok(Self.buildAXTree(maxDepth: depth))
        case ("POST", "/action"):
            return handleAction(req.body)
        case ("GET", "/action"):
            let action = req.query["action"] ?? ""
            var d: [String: Any] = ["action": action]
            for (k, v) in req.query where k != "action" { d[k] = v }
            if let data = try? JSONSerialization.data(withJSONObject: d) {
                return handleAction(String(data: data, encoding: .utf8) ?? "")
            }
            return ("400 Bad Request", Self.json(["error": "bad query"]))
        default:
            return ("404 Not Found", Self.json([
                "error": "not found",
                "endpoints": [
                    "GET  /health",
                    "GET  /state",
                    "GET  /ax[?depth=N]",
                    "POST /action  {action: connect|disconnect|ax-press|ax-set-value, ...}",
                    "GET  /action?action=...  (convenience alias)",
                ],
            ]))
        }
    }

    // MARK: - State

    @MainActor
    private func buildState() -> [String: Any] {
        guard let vpn else { return ["error": "VPNController not available"] }
        var dict: [String: Any] = [:]
        dict["connection"] = [
            "isConnected": vpn.isConnected,
            "isBusy": vpn.isBusy,
            "statusText": vpn.statusText,
            "connectedAt": vpn.connectedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            "tunnelInterface": vpn.tunnelInterface ?? "",
            "tunnelIP": vpn.tunnelIP ?? "",
            "vpnGateway": vpn.vpnGateway ?? "",
            "dnsProxyActive": vpn.dnsProxyActive,
            "trafficIn": vpn.trafficIn,
            "trafficOut": vpn.trafficOut,
            "activeRoutes": vpn.activeRoutes,
        ] as [String: Any]
        dict["config"] = [
            "server": vpn.server,
            "user": vpn.user,
            "protocol": vpn.protocolName,
            "splitEnabled": vpn.splitEnabled,
            "splitDomains": vpn.splitDomains,
            "sudoConfigured": vpn.sudoConfigured,
        ] as [String: Any]
        dict["windows"] = NSApp.windows.map { w -> [String: Any] in
            [
                "title": w.title,
                "isVisible": w.isVisible,
                "isKey": w.isKeyWindow,
                "frame": ["x": Int(w.frame.origin.x), "y": Int(w.frame.origin.y),
                          "w": Int(w.frame.width), "h": Int(w.frame.height)],
            ]
        }
        return dict
    }

    // MARK: - Actions

    @MainActor
    private func handleAction(_ body: String) -> (String, String) {
        guard let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = obj["action"] as? String else {
            return ("400 Bad Request", Self.json(["error": "missing or invalid 'action'"]))
        }
        guard let vpn else {
            return ("500 Internal Server Error", Self.json(["error": "VPNController unavailable"]))
        }

        switch action {
        case "connect":
            vpn.connect()
            return Self.ok(["ok": true])
        case "disconnect":
            vpn.disconnect()
            return Self.ok(["ok": true])
        case "fake-update":
            let version = obj["version"] as? String ?? "99.0.0"
            updater?.fakeUpdate(version: version)
            return Self.ok(["ok": true, "fakeVersion": version])
        case "clear-update":
            updater?.clearFakeUpdate()
            return Self.ok(["ok": true])
        case "ax-press":
            return Self.axPress(obj)
        case "ax-set-value":
            return Self.axSetValue(obj)
        default:
            return ("400 Bad Request", Self.json(["error": "unknown action: \(action)",
                "available": ["connect", "disconnect", "fake-update", "clear-update", "ax-press", "ax-set-value"]]))
        }
    }

    // MARK: - AX Tree

    @MainActor
    private static func buildAXTree(maxDepth: Int) -> [String: Any] {
        let app = AXUIElementCreateApplication(getpid())
        var result: [String: Any] = ["pid": getpid()]

        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
           let windows = ref as? [AXUIElement] {
            result["windows"] = windows.map { dumpAX($0, depth: 0, max: maxDepth) }
        } else {
            result["windows"] = [] as [Any]
        }

        if AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &ref) == .success {
            result["menuBar"] = dumpAX(ref as! AXUIElement, depth: 0, max: min(maxDepth, 5))
        }

        if AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &ref) == .success {
            result["extrasMenuBar"] = dumpAX(ref as! AXUIElement, depth: 0, max: min(maxDepth, 5))
        }

        return result
    }

    private static func dumpAX(_ el: AXUIElement, depth: Int, max maxDepth: Int) -> [String: Any] {
        var d: [String: Any] = [:]

        func str(_ attr: String) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
            return ref as? String
        }
        func flag(_ attr: String) -> Bool? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
            return (ref as? NSNumber)?.boolValue
        }

        if let v = str(kAXRoleAttribute) { d["role"] = v }
        if let v = str(kAXSubroleAttribute) { d["subrole"] = v }
        if let v = str(kAXTitleAttribute), !v.isEmpty { d["title"] = v }
        if let v = str(kAXDescriptionAttribute), !v.isEmpty { d["description"] = v }
        if let v = str("AXIdentifier"), !v.isEmpty { d["id"] = v }
        if let v = str(kAXRoleDescriptionAttribute), !v.isEmpty { d["roleDesc"] = v }

        var valRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valRef) == .success,
           let v = valRef {
            if let s = v as? String { d["value"] = s }
            else if let n = v as? NSNumber { d["value"] = n }
            else { d["value"] = "\(v)" }
        }

        if let v = flag(kAXEnabledAttribute), !v { d["enabled"] = false }
        if let v = flag(kAXFocusedAttribute), v { d["focused"] = true }

        var posRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
           posRef != nil, CFGetTypeID(posRef!) == AXValueGetTypeID() {
            var pt = CGPoint.zero
            AXValueGetValue(posRef as! AXValue, .cgPoint, &pt)
            d["x"] = Int(pt.x); d["y"] = Int(pt.y)
        }
        var szRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &szRef) == .success,
           szRef != nil, CFGetTypeID(szRef!) == AXValueGetTypeID() {
            var sz = CGSize.zero
            AXValueGetValue(szRef as! AXValue, .cgSize, &sz)
            d["w"] = Int(sz.width); d["h"] = Int(sz.height)
        }

        if depth < maxDepth {
            var chRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &chRef) == .success,
               let children = chRef as? [AXUIElement], !children.isEmpty {
                d["children"] = children.map { dumpAX($0, depth: depth + 1, max: maxDepth) }
            }
        }

        return d
    }

    // MARK: - AX Actions

    @MainActor
    private static func axPress(_ obj: [String: Any]) -> (String, String) {
        guard let title = obj["title"] as? String else {
            return ("400 Bad Request", json(["error": "missing 'title'"]))
        }
        let role = obj["role"] as? String
        let app = AXUIElementCreateApplication(getpid())
        guard let el = findAXElement(root: app, role: role, title: title) else {
            return ("404 Not Found", json(["error": "element not found", "title": title]))
        }
        let r = AXUIElementPerformAction(el, kAXPressAction as CFString)
        if r == .success { return Self.ok(["ok": true]) }
        return ("500 Internal Server Error", json(["error": "AXPress failed", "code": r.rawValue]))
    }

    @MainActor
    private static func axSetValue(_ obj: [String: Any]) -> (String, String) {
        guard let identifier = obj["title"] as? String ?? obj["id"] as? String,
              let value = obj["value"] as? String else {
            return ("400 Bad Request", json(["error": "missing 'title'/'id' or 'value'"]))
        }
        let role = obj["role"] as? String
        let app = AXUIElementCreateApplication(getpid())
        guard let el = findAXElement(root: app, role: role, title: identifier) else {
            return ("404 Not Found", json(["error": "element not found", "title": identifier]))
        }
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, true as CFTypeRef)
        let r = AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFTypeRef)
        if r == .success { return Self.ok(["ok": true]) }
        return ("500 Internal Server Error", json(["error": "set value failed", "code": r.rawValue]))
    }

    private static func findAXElement(root: AXUIElement, role: String?, title: String, maxDepth: Int = 20) -> AXUIElement? {
        func str(_ el: AXUIElement, _ attr: String) -> String? {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, attr as CFString, &ref) == .success else { return nil }
            return ref as? String
        }

        func search(_ el: AXUIElement, depth: Int) -> AXUIElement? {
            if depth > maxDepth { return nil }
            let elRole = str(el, kAXRoleAttribute)
            let texts = [
                str(el, kAXTitleAttribute),
                str(el, kAXDescriptionAttribute),
                str(el, "AXIdentifier"),
                str(el, kAXValueAttribute),
            ].compactMap { $0 }

            let titleMatch = texts.contains { $0.contains(title) }
            let roleMatch = role == nil || elRole == role

            if titleMatch && roleMatch { return el }

            var chRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &chRef) == .success,
                  let children = chRef as? [AXUIElement] else { return nil }
            for child in children {
                if let found = search(child, depth: depth + 1) { return found }
            }
            return nil
        }

        return search(root, depth: 0)
    }

    // MARK: - HTTP Parsing

    private static func parseHTTP(_ raw: String) -> (method: String, path: String, query: [String: String], body: String) {
        let headerEnd = raw.range(of: "\r\n\r\n")
        let body = headerEnd.map { String(raw[$0.upperBound...]) } ?? ""
        let firstLine = String(raw.prefix(while: { $0 != "\r" && $0 != "\n" }))
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return ("GET", "/", [:], body) }
        let method = String(parts[0])
        let fullPath = String(parts[1])

        let pathParts = fullPath.split(separator: "?", maxSplits: 1)
        let path = String(pathParts[0])
        var query: [String: String] = [:]
        if pathParts.count > 1 {
            for pair in pathParts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    query[String(kv[0])] = String(kv[1]).removingPercentEncoding ?? String(kv[1])
                } else if kv.count == 1 {
                    query[String(kv[0])] = ""
                }
            }
        }
        return (method, path, query, body)
    }

    // MARK: - JSON Helpers

    private static func ok(_ dict: [String: Any]) -> (String, String) {
        ("200 OK", json(dict))
    }

    private static func json(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
#endif
