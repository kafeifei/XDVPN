public enum RouteInstallResult: Equatable, Sendable {
    case installed
    case alreadyOwned
    case failed
}

/// Tracks only routes whose installation was confirmed successful.
public struct RouteOwnershipTracker<Route: Hashable> {
    public private(set) var ownedRoutes = Set<Route>()

    public init() {}

    public mutating func installIfNeeded(
        _ route: Route,
        install: () -> Bool
    ) -> RouteInstallResult {
        if ownedRoutes.contains(route) { return .alreadyOwned }
        guard install() else { return .failed }
        ownedRoutes.insert(route)
        return .installed
    }
}
