import XCTest
import Darwin
import Foundation
import CatalystConnect
import CatalystConnectObjects
import CatalystUsers

@MainActor final class NativeUsersTests: XCTestCase {
    func testCreateUserAgainstAuthoritativeGemStone() async throws {
        let bundle = Bundle(for: NativeUsersTests.self)
        let url = ProcessInfo.processInfo.environment["CONNECT_TEST_CONFIGURATION"].map { URL(fileURLWithPath: $0) }
            ?? bundle.url(forResource: "client", withExtension: "json")
        guard let url else { throw XCTSkip("Use the managed GemStone platform runner") }
        let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let prefix = try XCTUnwrap(config["prefix"] as? String)
        func file(_ key: String) -> String {
            let path = config[key] as! String
            return path.hasPrefix("/") ? path : bundle.bundleURL.appendingPathComponent(path).path
        }
        let transport = ConnectClient(configuration: ConnectConfiguration(peer: config["peer"] as! String,
            serverName: "localhost", certificate: file("certificate"), privateKey: file("private_key"),
            trustedCertificate: file("trusted_certificate"), bind: "127.0.0.1:0", capacity: 4))
        try await transport.connect()
        do {
            let users = try CUUsers(connect: transport)
            do { _ = try await users.createUser(CUUser(name: prefix + ":not-ready")); XCTFail("Call before agreement") }
            catch { XCTAssertEqual(error as? ObjectBindingError, .notReady) }
            do { _ = try await users.getUser(named: "admin"); XCTFail("Lookup before agreement") }
            catch { XCTAssertEqual(error as? ObjectBindingError, .notReady) }
            try await users.prepare()
            let schema = try ObjectSchema(exemplar: CUUser())
            let badManifest = try JSONSerialization.data(withJSONObject: [1, String(repeating: "0", count: 64), schema.revision])
            let rejected = try await transport.request(operation: 65534, body: badManifest)
            XCTAssertEqual(rejected.status, 400)
            let input = CUUser(name: prefix + ":hold")
            let committed = try await users.createUser(input)
            XCTAssertEqual(committed.name, input.name); XCTAssertFalse(committed.isSuperUser); XCTAssertFalse(committed === input)
            let marker = try JSONSerialization.data(withJSONObject: ["prefix": prefix, "nativeType": "CUUser", "completed": true])
            #if os(iOS)
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            try marker.write(to: documents.appendingPathComponent("cu-platform-success.json"), options: .atomic)
            #endif
            print("CU_PLATFORM_SUCCESS \(prefix)"); fflush(nil)
            if let output = ProcessInfo.processInfo.environment["CU_OUTPUT"] {
                try Data("{\"nativeType\":\"CUUser\",\"completed\":true}".utf8).write(to: URL(fileURLWithPath: output).appendingPathComponent("client-success.json"))
            }
            let fetchedValue = try await users.getUser(named: input.name)
            let fetched = try XCTUnwrap(fetchedValue)
            XCTAssertEqual(fetched.name, input.name); XCTAssertFalse(fetched.isSuperUser)
            XCTAssertFalse(fetched === committed)
            let missing = try await users.getUser(named: prefix + ":missing")
            XCTAssertNil(missing)
            let wrongCase = try await users.getUser(named: input.name.uppercased())
            XCTAssertNil(wrongCase)
            let admin = try await users.getUser(named: "admin")
            XCTAssertEqual(admin?.name, "admin"); XCTAssertEqual(admin?.isSuperUser, true)
            let unknown = try await users.getUser(named: "unknownUser")
            XCTAssertEqual(unknown?.name, "unknownUser"); XCTAssertEqual(unknown?.isSuperUser, false)
            let duplicateName = prefix + ":duplicate"
            _ = try await users.createUser(CUUser(name: duplicateName))
            _ = try await users.createUser(CUUser(name: duplicateName))
            do { _ = try await users.getUser(named: duplicateName); XCTFail("Ambiguous name returned a user") }
            catch { XCTAssertEqual(error as? ObjectBindingError, .refused(status: 422)) }
            for (suffix, superUser) in [(":rollback", false), (":super", true)] {
                let user = CUUser(name: prefix + suffix); user.isSuperUser = superUser
                do { _ = try await users.createUser(user); XCTFail("Failed transaction returned a user") }
                catch { XCTAssertEqual(error as? ObjectBindingError, .unknown) }
            }
            let rolledBack = try await users.getUser(named: prefix + ":rollback")
            XCTAssertNil(rolledBack)
            await transport.close(); try await transport.connect()
            do { _ = try await users.getUser(named: input.name); XCTFail("Lookup reused stale agreement") }
            catch { XCTAssertEqual(error as? ConnectError, .notReady) }
            do { _ = try await users.createUser(CUUser(name: prefix + ":stale")); XCTFail("Reused stale agreement") }
            catch { XCTAssertEqual(error as? ConnectError, .notReady) }
            try await users.prepare()
            let reconnectedName = try XCTUnwrap(config["reconnectedName"] as? String)
            let reconnected = try await users.createUser(CUUser(name: reconnectedName))
            XCTAssertEqual(reconnected.name, reconnectedName); XCTAssertFalse(reconnected.isSuperUser)
            let lookedUpAgain = try await users.getUser(named: reconnectedName)
            XCTAssertEqual(lookedUpAgain?.name, reconnectedName); XCTAssertEqual(lookedUpAgain?.isSuperUser, false)
            print("CU_PLATFORM_LOOKUP_RESULT \(prefix) found not-found ambiguous-refused exact-case defaults rollback-absent unicode reconnect")
            print("CU_PLATFORM_RESULT \(prefix) completed rollback-unknown super-unknown mismatch-refused reconnect-completed")
        } catch { await transport.close(); throw error }
        await transport.close()
    }
}
