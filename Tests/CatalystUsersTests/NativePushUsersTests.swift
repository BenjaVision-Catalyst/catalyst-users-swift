import XCTest
import Foundation
import CatalystConnect
import CatalystConnectObjects
import CatalystUsers

@MainActor final class NativePushUsersTests: XCTestCase {
    func testAuthorityPushAndReconnect() async throws {
        let bundle = Bundle(for: NativePushUsersTests.self)
        let url = ProcessInfo.processInfo.environment["CONNECT_TEST_CONFIGURATION"].map { URL(fileURLWithPath: $0) }
            ?? bundle.url(forResource: "client", withExtension: "json")
        guard let url else { throw XCTSkip("Use the managed Users push runner") }
        let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let prefix = config["prefix"] as! String
        func file(_ key: String) -> String {
            let path = config[key] as! String
            return path.hasPrefix("/") ? path : bundle.bundleURL.appendingPathComponent(path).path
        }
        func connection() -> ConnectClient {
            ConnectClient(configuration: ConnectConfiguration(peer: config["peer"] as! String, serverName: "localhost",
                certificate: file("certificate"), privateKey: file("private_key"), trustedCertificate: file("trusted_certificate"),
                bind: "127.0.0.1:0", capacity: 4))
        }
        func marker(_ name: String) throws {
            #if os(iOS)
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            #else
            let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CU_OUTPUT"]!)
            #endif
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["prefix": prefix]).write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        func waitFor(_ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(20)
            while !predicate() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            guard predicate() else { throw NSError(domain: "NativePushUsersTests timeout", code: 1) }
        }
        let main = connection(), remote = connection()
        try await main.connect(); try await remote.connect()
        var policy = CULiveUserPolicy(); policy.automaticRefresh = false; policy.refreshInterval = .milliseconds(50)
        let users = try CUUsers(connect: main, livePolicy: policy)
        var automatic = policy; automatic.automaticRefresh = true
        let observers = try CUUsers(connect: remote, livePolicy: automatic)
        users.onError = { _, _ in }; observers.onError = { _, _ in }
        do {
            let original = CUUser(name: prefix + ":push-original")
            let adopted = try await users.createUser(original).value(); XCTAssertTrue(adopted === original)
            let cached = try await users.getUser(named: original.name); XCTAssertTrue(cached === original)
            let observedValue = try await observers.getUser(named: original.name)
            let observed = try XCTUnwrap(observedValue)
            XCTAssertEqual(observed.replica.identifier, original.replica.identifier)
            try await Task.sleep(for: .milliseconds(300))
            try marker("idle-start.json")
            try await Task.sleep(for: .seconds(16)) // Covers a lease heartbeat; no periodic User reads.
            try marker("idle-end.json")
            original.name = prefix + ":push-held"
            await users.synchronizeNow() // Trusted controller holds this before commit/finalization.
            try await waitFor { observed.name == prefix + ":push-held" }
            try marker("push-observed.json")
            if config["authority"] as? String != "gt" {
                original.name = prefix + ":push-rollback"; await users.synchronizeNow()
                XCTAssertEqual(original.replica.phase, .uncertain)
                try await Task.sleep(for: .milliseconds(300))
                XCTAssertEqual(observed.name, prefix + ":push-held"); XCTAssertEqual(observed.replica.revision, 2)
                await users.synchronizeNow(); users.resolveConflict(original, keepLocal: false)
            }
            original.name = prefix + ":local-draft"; observed.name = prefix + ":push-authority"
            try await waitFor { !observed.replica.hasEdits }
            await users.synchronizeNow()
            XCTAssertEqual(original.replica.phase, .conflict); XCTAssertEqual(original.name, prefix + ":local-draft")
            users.resolveConflict(original, keepLocal: false)
            XCTAssertEqual(original.name, prefix + ":push-authority")
            await main.close()
            observed.name = prefix + ":push-disconnected"
            try await waitFor { !observed.replica.hasEdits }
            try users.configureLiveUsers(automatic); try await main.connect()
            try await waitFor { original.name == prefix + ":push-disconnected" }
            observed.name = prefix + ":push-reconnected"
            try await waitFor { original.name == observed.name && !observed.replica.hasEdits }
            let recovered = try await users.getUser(named: original.name); XCTAssertTrue(recovered === original)
            XCTAssertEqual(original.replica.identifier, observed.replica.identifier)
            try marker("push-success.json")
            print("CU_PUSH_RESULT \(prefix) no-periodic-reads pushed-after-finalization stable-identity conflict reconnect")
        } catch {
            users.stopObserving(); observers.stopObserving(); await main.close(); await remote.close(); throw error
        }
        users.stopObserving(); observers.stopObserving(); await main.close(); await remote.close()
    }
}
