import XCTest
import Foundation
import Magritte
import CatalystConnectObjects
@testable import CatalystUsers

@MainActor final class SchemaTests: XCTestCase {
    func testLiveProfilePreservesLegacyAndReadOnlyMetadata() throws {
        let request = try ObjectSchema(exemplar: CUUserChange(), profile: .stateV2)
        let result = try ObjectSchema(exemplar: CULiveUserState(), profile: .stateV2)
        XCTAssertEqual(request.revision, "71f6a5241e5dea62f3bc651e8a1b3aafe8ddfcaae9eda7e147807c865adadbf1")
        XCTAssertEqual(result.revision, "6f4dc62ac9dfdcb45922152eb2f18d591222476b2ca5b1ccfc34676065fb4985")
        XCTAssertThrowsError(try ObjectSchema(exemplar: CULiveUserState()))
        let state = CULiveUserState(); state.name = "State é🛰"; state.userIdentifier = "id"; state.revision = 2; state.outcome = "current"
        let decoded = try result.decode(result.encode(state))
        XCTAssertEqual(decoded.name, state.name); XCTAssertEqual(decoded.userIdentifier, "id"); XCTAssertEqual(decoded.revision, 2)
        let readonly = state.magritteDescription().children.filter { (try? $0.flag("readOnly")) == true }
        XCTAssertEqual(readonly.count, 4)
    }
    func testReplicaPreservesEditsAndRequiresExplicitConflictResolution() {
        var replica = ObjectReplicaState(); replica.edited()
        let submitted = replica.editSequence; replica.transition(.creating); replica.edited()
        XCTAssertFalse(replica.accept(identifier: "id", revision: 1, sentSequence: submitted))
        XCTAssertTrue(replica.hasEdits); XCTAssertEqual(replica.editBase, 1)
        XCTAssertFalse(replica.accept(identifier: "id", revision: 2))
        XCTAssertEqual(replica.phase, .conflict)
        replica.rebaseLocal(); XCTAssertEqual(replica.editBase, 2)
        XCTAssertTrue(replica.accept(identifier: "id", revision: 3, sentSequence: replica.editSequence))
        XCTAssertFalse(replica.hasEdits)
        XCTAssertFalse(replica.accept(identifier: "replacement", revision: 4))
        XCTAssertEqual(replica.identifier, "id"); XCTAssertEqual(replica.revision, 3)
    }
    func testReadCannotAuthorizeReplayOfAnUncertainWrite() {
        var replica = ObjectReplicaState()
        XCTAssertTrue(replica.accept(identifier: "id", revision: 1))
        replica.edited(); replica.transition(.uncertain)
        XCTAssertFalse(replica.accept(identifier: "id", revision: 1))
        XCTAssertEqual(replica.phase, .uncertain)
        XCTAssertFalse(replica.accept(identifier: "id", revision: 2))
        XCTAssertEqual(replica.phase, .uncertain)
        replica.acceptRemote(); XCTAssertFalse(replica.hasEdits)
        replica.transition(.uncertain); XCTAssertTrue(replica.accept(identifier: "id", revision: 2))
        XCTAssertEqual(replica.phase, .live)
    }
    func testLookupReusesUserNameDescription() throws {
        let schema = try ObjectSchema(exemplar: CUUserLookup())
        XCTAssertEqual(schema.revision, "31b7f14dece1b6bbf864672c923ae7a0170b058c053bec846e9db8be5ed0e8f1")
        let query = CUUserLookup(name: "Ada é🛰/\"")
        XCTAssertEqual(try schema.decode(schema.encode(query)).name, query.name)
        XCTAssertThrowsError(try schema.encode(CUUserLookup(name: String(repeating: "é", count: 513))))
        XCTAssertThrowsError(try schema.decode(Data("[\"\(schema.revision)\",[null]]".utf8)))
    }
    func testNativeUserAgreesWithLiveSmalltalkDescription() throws {
        let schema = try ObjectSchema(exemplar: CUUser())
        XCTAssertEqual(schema.revision, "742282f3bd6d47c824c6c12a2244dcb79ac5b13ba1d94aa4bd60b843608185cb")
        let user = CUUser(name: "Ada 🛰 / \\");
        let result = try schema.decode(schema.encode(user))
        XCTAssertEqual(result.name, user.name)
        XCTAssertFalse(result.isSuperUser)
        XCTAssertFalse(result === user)
        XCTAssertEqual(try schema.decode(schema.encode(CUUser())).name, "")
        XCTAssertThrowsError(try schema.decode(Data("[\"\(schema.revision)\",[false,null]]".utf8)))
        XCTAssertThrowsError(try schema.encode(CUUser(name: String(repeating: "é", count: 513))))
        XCTAssertThrowsError(try schema.decode(Data("{}".utf8)))
        XCTAssertThrowsError(try schema.decode(Data("[\"wrong\",[false,\"Ada\"]]".utf8)))
        XCTAssertThrowsError(try schema.decode(Data("[\"\(schema.revision)\",[1,\"Ada\"]]".utf8)))
    }
}
