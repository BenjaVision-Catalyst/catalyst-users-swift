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
            var policy = CULiveUserPolicy(); policy.automaticRefresh = false; policy.refreshInterval = .milliseconds(50)
            let users = try CUUsers(connect: transport, livePolicy: policy)
            users.onError = { _, _ in }
            do { _ = try await users.createUserSnapshot(CUUser(name: prefix + ":not-ready")); XCTFail("Call before agreement") }
            catch { XCTAssertEqual(error as? ObjectBindingError, .notReady) }
            do { _ = try await users.getUserSnapshot(named: "admin"); XCTFail("Lookup before agreement") }
            catch { XCTAssertEqual(error as? ObjectBindingError, .notReady) }
            try await users.prepare()
            let schema = try ObjectSchema(exemplar: CUUser())
            let badManifest = try JSONSerialization.data(withJSONObject: [1, String(repeating: "0", count: 64), schema.revision])
            let rejected = try await transport.request(operation: 65534, body: badManifest)
            XCTAssertEqual(rejected.status, 400)
            let input = CUUser(name: prefix + ":hold")
            let committed = try await users.createUserSnapshot(input)
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
            let fetchedValue = try await users.getUserSnapshot(named: input.name)
            let fetched = try XCTUnwrap(fetchedValue)
            XCTAssertEqual(fetched.name, input.name); XCTAssertFalse(fetched.isSuperUser)
            XCTAssertFalse(fetched === committed)
            let missing = try await users.getUserSnapshot(named: prefix + ":missing")
            XCTAssertNil(missing)
            let wrongCase = try await users.getUserSnapshot(named: input.name.uppercased())
            XCTAssertNil(wrongCase)
            let admin = try await users.getUserSnapshot(named: "admin")
            XCTAssertEqual(admin?.name, "admin"); XCTAssertEqual(admin?.isSuperUser, true)
            let unknown = try await users.getUserSnapshot(named: "unknownUser")
            XCTAssertEqual(unknown?.name, "unknownUser"); XCTAssertEqual(unknown?.isSuperUser, false)
            let duplicateName = prefix + ":duplicate"
            _ = try await users.createUserSnapshot(CUUser(name: duplicateName))
            _ = try await users.createUserSnapshot(CUUser(name: duplicateName))
            do { _ = try await users.getUserSnapshot(named: duplicateName); XCTFail("Ambiguous name returned a user") }
            catch { XCTAssertEqual(error as? ObjectBindingError, .refused(status: 422)) }
            for (suffix, superUser) in [(":rollback", false), (":super", true)] {
                let user = CUUser(name: prefix + suffix); user.isSuperUser = superUser
                do { _ = try await users.createUserSnapshot(user); XCTFail("Failed transaction returned a user") }
                catch { XCTAssertEqual(error as? ObjectBindingError, .unknown) }
            }
            let rolledBack = try await users.getUserSnapshot(named: prefix + ":rollback")
            XCTAssertNil(rolledBack)
            await transport.close(); try await transport.connect()
            do { _ = try await users.getUserSnapshot(named: input.name); XCTFail("Lookup reused stale agreement") }
            catch { XCTAssertEqual(error as? ConnectError, .notReady) }
            do { _ = try await users.createUserSnapshot(CUUser(name: prefix + ":stale")); XCTFail("Reused stale agreement") }
            catch { XCTAssertEqual(error as? ConnectError, .notReady) }
            try await users.prepare()
            let reconnectedName = try XCTUnwrap(config["reconnectedName"] as? String)
            let reconnected = try await users.createUserSnapshot(CUUser(name: reconnectedName))
            XCTAssertEqual(reconnected.name, reconnectedName); XCTAssertFalse(reconnected.isSuperUser)
            let lookedUpAgain = try await users.getUserSnapshot(named: reconnectedName)
            XCTAssertEqual(lookedUpAgain?.name, reconnectedName); XCTAssertEqual(lookedUpAgain?.isSuperUser, false)
            // The framework adopts the submitted native instance and preserves a newer pending edit.
            let live = CUUser(name: prefix + ":live")
            let operation = users.createUser(live)
            live.name = prefix + ":live-edited"
            let adopted = try await operation.value()
            XCTAssertTrue(adopted === live); XCTAssertFalse(live.replica.identifier.isEmpty)
            XCTAssertEqual(live.replica.revision, 1); XCTAssertTrue(live.replica.hasEdits)
            await users.synchronizeNow()
            XCTAssertEqual(live.replica.revision, 2); XCTAssertFalse(live.replica.hasEdits)
            let cached = try await users.getUser(named: live.name)
            XCTAssertTrue(cached === live)
            let sharedUsers = try CUUsers(connect: transport)
            let shared = try await sharedUsers.getUser(named: live.name)
            XCTAssertTrue(shared === live)
            let remoteTransport = ConnectClient(configuration: ConnectConfiguration(peer: config["peer"] as! String,
                serverName: "localhost", certificate: file("certificate"), privateKey: file("private_key"),
                trustedCertificate: file("trusted_certificate"), bind: "127.0.0.1:0", capacity: 4))
            try await remoteTransport.connect()
            var remotePolicy = policy; remotePolicy.automaticRefresh = true
            let remoteUsers = try CUUsers(connect: remoteTransport, livePolicy: remotePolicy)
            remoteUsers.onError = { _, _ in }
            do {
                let otherValue = try await remoteUsers.getUser(named: live.name)
                let other = try XCTUnwrap(otherValue)
                XCTAssertFalse(other === live); XCTAssertEqual(other.replica.identifier, live.replica.identifier)
                func waitFor(_ predicate: () -> Bool) async throws {
                    let deadline = ContinuousClock.now + .seconds(15)
                    while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
                    XCTAssertTrue(predicate())
                }
                live.name = prefix + ":live-remote"; await users.synchronizeNow()
                try await waitFor { other.name == live.name }
                live.name = prefix + ":live-local-draft"
                other.name = prefix + ":live-authority"
                try await waitFor { !other.replica.hasEdits && other.name == prefix + ":live-authority" }
                await users.synchronizeNow()
                XCTAssertEqual(live.replica.phase, .conflict); XCTAssertEqual(live.name, prefix + ":live-local-draft")
                users.resolveConflict(live, keepLocal: false)
                XCTAssertEqual(live.name, prefix + ":live-authority"); XCTAssertFalse(live.replica.hasEdits)
            } catch { remoteUsers.stopObserving(); await remoteTransport.close(); throw error }
            remoteUsers.stopObserving(); await remoteTransport.close()
            let rollback = CUUser(name: prefix + ":live-rollback")
            do { _ = try await users.createUser(rollback).value(); XCTFail("Live rollback returned a user") } catch {}
            await users.synchronizeNow()
            XCTAssertTrue(rollback.replica.identifier.isEmpty)
            let rollbackLookup = try await users.getUser(named: rollback.name); XCTAssertNil(rollbackLookup)
            policy.automaticRefresh = true; try users.configureLiveUsers(policy)
            let lost = CUUser(name: prefix + ":lost-create")
            let lostOperation = users.createUser(lost)
            try await Task.sleep(for: .seconds(1))
            await transport.close()
            do { _ = try await lostOperation.value(); XCTFail("Lost reply reported confirmation") } catch {}
            XCTAssertEqual(lost.replica.phase, .uncertain); XCTAssertTrue(lost.replica.identifier.isEmpty)
            let disconnected = try JSONSerialization.data(withJSONObject: ["prefix": prefix])
            #if os(iOS)
            try disconnected.write(to: documents.appendingPathComponent("live-disconnected.json"), options: .atomic)
            #else
            try disconnected.write(to: URL(fileURLWithPath: ProcessInfo.processInfo.environment["CU_OUTPUT"]!).appendingPathComponent("live-disconnected.json"), options: .atomic)
            #endif
            lost.name = prefix + ":recovered-edit"
            try await transport.connect() // Fabric renegotiates and recovers without another Users.prepare().
            let deadline = ContinuousClock.now + .seconds(20)
            while (lost.replica.identifier.isEmpty || lost.replica.hasEdits) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertFalse(lost.replica.identifier.isEmpty); XCTAssertFalse(lost.replica.hasEdits)
            XCTAssertEqual(lost.name, prefix + ":recovered-edit"); XCTAssertEqual(lost.replica.phase, .live)
            let recovered = try await users.getUser(named: lost.name); XCTAssertTrue(recovered === lost)
            users.stopObserving()
            print("CU_LIVE_RESULT \(prefix) adopted stable-identity shared-cache auto-refresh conflict lost-create-recovered rollback-absent")
            print("CU_PLATFORM_LOOKUP_RESULT \(prefix) found not-found ambiguous-refused exact-case defaults rollback-absent unicode reconnect")
            print("CU_PLATFORM_RESULT \(prefix) completed rollback-unknown super-unknown mismatch-refused reconnect-completed")
        } catch { await transport.close(); throw error }
        await transport.close()
    }
}
