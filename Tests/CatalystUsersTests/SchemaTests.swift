import XCTest
import Foundation
import Magritte
import CatalystConnectObjects
@testable import CatalystUsers

@MainActor final class SchemaTests: XCTestCase {
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
