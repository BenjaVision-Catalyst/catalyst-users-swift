import CatalystConnect
import CatalystConnectObjects

/// Users API over a caller-owned Connect session. No store or transport state in CUUser.
@MainActor public final class CUUsers {
    private let live: CULiveUsersContext
    private let endpoint: ObjectBinding<CUUser, CUUser>
    private let lookup: ObjectBinding<CUUserLookup, CUUser>
    public init(connect: ConnectClient, livePolicy: CULiveUserPolicy = CULiveUserPolicy()) throws {
        live = try CULiveUsersContext.shared(connect, policy: livePolicy)
        endpoint = try ObjectBinding(transport: connect, operation: 1, request: CUUser(), result: CUUser())
        lookup = try ObjectBinding(transport: connect, operation: 2, request: CUUserLookup(), result: CUUser())
    }
    public func prepare() async throws {
        try await endpoint.prepare()
        try await lookup.prepare()
    }
    public func createUserSnapshot(_ user: CUUser) async throws -> CUUser { try await endpoint.call(user) }
    /// nil is an explicit committed not-found response; ambiguous names throw refused(status: 422).
    public func getUserSnapshot(named name: String) async throws -> CUUser? {
        do { return try await lookup.call(CUUserLookup(name: name)) }
        catch ObjectBindingError.notFound { return nil }
    }
    @discardableResult public func createUser(_ user: CUUser) -> ObjectOperation<CUUser> { live.createUser(user) }
    public func getUser(named name: String) async throws -> CUUser? { try await live.getUser(named: name) }
    public func synchronizeNow() async { await live.synchronize() }
    public func resolveConflict(_ user: CUUser, keepLocal: Bool) { live.resolve(user, keepLocal: keepLocal) }
    public var onError: ((CUUser, Error) -> Void)? { get { live.onError } set { live.onError = newValue } }
    public func configureLiveUsers(_ policy: CULiveUserPolicy) throws { try live.configure(policy) }
    public func stopObserving() { live.stop() }
}
