import CatalystConnect
import CatalystConnectObjects

/// Users API over a caller-owned Connect session. No store or transport state in CUUser.
@MainActor public final class CUUsers {
    private let endpoint: ObjectBinding<CUUser, CUUser>
    public init(connect: ConnectClient) throws {
        endpoint = try ObjectBinding(transport: connect, operation: 1, request: CUUser(), result: CUUser())
    }
    public func prepare() async throws { try await endpoint.prepare() }
    public func createUser(_ user: CUUser) async throws -> CUUser { try await endpoint.call(user) }
}
