import Foundation

/// 运行模式（与 VPNController.RunningMode 对应，但放在纯核心里以便单测）。
public enum RunMode: Sendable, Equatable {
    case proxy, split, full
}

/// 隧道健康判定结果。驱动「是否触发自动重连」。
public enum TunnelVerdict: Sendable, Equatable {
    case notConnected       // 没声称连着 → 无需动作
    case healthy            // 正常
    case processDead        // 进程没了 → 重连
    case blackholeSuspect   // 进程活着但隧道疑似黑洞 → 重连
}

/// 一次健康采样的事实输入（全部由调用方从系统采集，本判定是纯函数）。
public struct TunnelFacts: Sendable {
    public var declaredConnected: Bool
    public var processAlive: Bool
    public var mode: RunMode
    public var secsSinceConnect: TimeInterval
    public var graceSeconds: TimeInterval

    // full 模式信号
    public var defaultRouteOnUtun: Bool?     // nil = 未知/不适用

    // 流量停滞信号（仅 full 模式可靠；split 下 utun 长期零流量是常态，不用）
    public var inboundStalledSeconds: TimeInterval
    public var stallThreshold: TimeInterval
    public var hadInboundEverSinceConnect: Bool
    public var outboundActive: Bool          // 本端在发包

    // proxy 模式信号
    public var socksReachable: Bool?         // nil = 未探测

    public init(
        declaredConnected: Bool,
        processAlive: Bool,
        mode: RunMode,
        secsSinceConnect: TimeInterval = 9999,
        graceSeconds: TimeInterval = 15,
        defaultRouteOnUtun: Bool? = nil,
        inboundStalledSeconds: TimeInterval = 0,
        stallThreshold: TimeInterval = 30,
        hadInboundEverSinceConnect: Bool = true,
        outboundActive: Bool = false,
        socksReachable: Bool? = nil
    ) {
        self.declaredConnected = declaredConnected
        self.processAlive = processAlive
        self.mode = mode
        self.secsSinceConnect = secsSinceConnect
        self.graceSeconds = graceSeconds
        self.defaultRouteOnUtun = defaultRouteOnUtun
        self.inboundStalledSeconds = inboundStalledSeconds
        self.stallThreshold = stallThreshold
        self.hadInboundEverSinceConnect = hadInboundEverSinceConnect
        self.outboundActive = outboundActive
        self.socksReachable = socksReachable
    }
}

/// 纯健康判定。按模式分别给出诚实信号：
/// - 进程没了 → processDead（任何模式）
/// - full：默认路由逃离 utun，或「在发包但收方向长期停滞且之前有过流量」→ blackholeSuspect
/// - split：utun 长期零流量是常态，**不**用字节停滞判黑洞（避免误杀）；只靠进程存活
/// - proxy：SOCKS5 端口不可达 → blackholeSuspect
public func diagnoseTunnel(_ f: TunnelFacts) -> TunnelVerdict {
    guard f.declaredConnected else { return .notConnected }
    guard f.processAlive else { return .processDead }
    // 建链初期宽限：不在这段时间内判黑洞，避免握手/路由尚未就绪时误杀
    guard f.secsSinceConnect >= f.graceSeconds else { return .healthy }

    switch f.mode {
    case .full:
        if f.defaultRouteOnUtun == false { return .blackholeSuspect }
        // 在发包、收方向连续停滞超阈值、且之前确有过入站流量 → 真黑洞而非空闲
        if f.outboundActive,
           f.hadInboundEverSinceConnect,
           f.inboundStalledSeconds >= f.stallThreshold {
            return .blackholeSuspect
        }
        return .healthy
    case .split:
        // 没有可靠的被动黑洞信号（治本需 --force-dpd）；进程活着即视为健康
        return .healthy
    case .proxy:
        if f.socksReachable == false { return .blackholeSuspect }
        return .healthy
    }
}
