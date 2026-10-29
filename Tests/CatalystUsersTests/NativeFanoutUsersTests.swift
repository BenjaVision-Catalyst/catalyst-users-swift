import XCTest
import Foundation
import Combine
import CatalystConnect
import CatalystConnectObjects
import CatalystUsers

private struct FanoutState: Codable {
    var userIdentifier: String
    var name: String
    var revision: Int64
    init(_ state: CULiveUserState) {
        userIdentifier = state.userIdentifier; name = state.name; revision = state.revision
    }
}

@MainActor private final class FanoutObserver {
    let index: Int, transport: ConnectClient, slow: Bool
    var users: CUUsers?, values: [CUUser] = [], identities: [ObjectIdentifier] = []
    var subscription: ConnectSubscription?, reading: Task<Void, Never>?
    var receiver: ObjectBinding<CUUserChange, CULiveUserState>?
    var read: ObjectBinding<CUUserChange, CULiveUserState>?
    var states: [String: FanoutState] = [:]
    var arrivals: [[String: Any]] = [], errors: [String] = []
    var tokens: [AnyCancellable] = [], requests: UInt64 = 0, slowProbeMillis = 0.0
    var stalledStatistics: [String: UInt64] = [:]
    var disconnected = false, last: [String: Int64] = [:]
    init(index: Int, transport: ConnectClient, slow: Bool) {
        self.index = index; self.transport = transport; self.slow = slow
    }
    func record(_ state: FanoutState) {
        if let previous = last[state.userIdentifier], state.revision < previous {
            errors.append("Revision moved backwards")
        }
        if state.revision > (last[state.userIdentifier] ?? 0) {
            arrivals.append(["user": state.userIdentifier, "revision": state.revision,
                             "at": ProcessInfo.processInfo.systemUptime])
            last[state.userIdentifier] = state.revision
        }
        states[state.userIdentifier] = state
    }
    static var policy: CULiveUserPolicy {
        var value = CULiveUserPolicy(); value.refreshInterval = .milliseconds(50); return value
    }
    func setUp(_ seed: [FanoutState]) async throws {
        try await transport.connect(timeout: .seconds(15))
        if slow {
            try await prepareSlow(seed)
        } else {
            let api = try CUUsers(connect: transport, livePolicy: Self.policy); users = api
            api.onError = { [weak self] _, error in self?.errors.append(String(describing: error)) }
            for expected in seed {
                let found = try await api.getUser(named: expected.name)
                let user = try XCTUnwrap(found)
                XCTAssertEqual(user.replica.identifier, expected.userIdentifier)
                values.append(user)
                tokens.append(user.objectWillChange.sink { [weak self, weak user] in
                    Task { @MainActor in
                        guard let user, let self else { return }
                        self.record(self.snapshotValue(user))
                    }
                })
                record(snapshotValue(user))
            }
            identities = values.map(ObjectIdentifier.init)
            try await eventually {
                let active = await self.transport.activeSubscriptionCount
                let submitted = (try? await self.transport.submittedRequestCount()) ?? 0
                // Seven agreements, three reads, three watch registrations and one channel.
                return active == 1 && submitted >= 14
            }
        }
        requests = try await transport.submittedRequestCount()
    }
    private func snapshotValue(_ user: CUUser) -> FanoutState {
        let value = CULiveUserState(); value.userIdentifier = user.replica.identifier
        value.name = user.name; value.revision = user.replica.revision; return FanoutState(value)
    }
    func prepareSlow(_ seed: [FanoutState]) async throws {
        let probe = try ObjectBinding(transport: transport, operation: 4, request: CUUserChange(), result: CULiveUserState(), profile: .stateV2)
        let watch = try ObjectBinding(transport: transport, operation: 7, request: CUUserChange(), result: CULiveUserState(), profile: .stateV2)
        let receive = try ObjectBinding(transport: transport, operation: 8, request: CUUserChange(), result: CULiveUserState(), profile: .stateV2)
        try await probe.prepare(); try await watch.prepare(); try await receive.prepare()
        let key = UUID().uuidString
        for expected in seed {
            let request = CUUserChange(); request.userIdentifier = expected.userIdentifier; request.operationIdentifier = key
            let current = try await probe.call(request)
            XCTAssertEqual(current.userIdentifier, expected.userIdentifier)
            record(FanoutState(current))
            request.operationIdentifier = key; request.expectedRevision = current.revision
            let response = try await watch.call(request); XCTAssertEqual(response.outcome, "current")
        }
        let request = CUUserChange(); request.operationIdentifier = key
        let (channel, response) = try await receive.subscribe(request)
        XCTAssertEqual(response.outcome, "subscribed")
        read = probe; receiver = receive; subscription = channel
        // Intentionally no iterator: the public stream's bounded buffer holds the
        // oldest native claim and eventually applies real QUIC flow control.
    }
    func consume() {
        guard reading == nil, let subscription, let receiver else { return }
        reading = Task { @MainActor [weak self] in
            do {
                for try await reply in subscription.events {
                    guard let self else { return }
                    self.record(FanoutState(try receiver.decodeNotification(reply)))
                }
            } catch { self?.errors.append(String(describing: error)) }
        }
    }
    func reached(_ expected: [FanoutState]) -> Bool {
        expected.allSatisfy { target in
            guard let actual = states[target.userIdentifier] else { return false }
            return actual.revision == target.revision && actual.name == target.name
        }
    }
    func assertReached(_ expected: [FanoutState]) async throws {
        try await eventually { self.reached(expected) }
        if !slow { XCTAssertEqual(values.map(ObjectIdentifier.init), identities) }
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
    }
    func probeWhileStalled(_ expected: [FanoutState]) async throws {
        stalledStatistics = try await transport.nativeStatistics()
        XCTAssertEqual(stalledStatistics["records"], stalledStatistics["capacity"], "Slow consumer must exhaust its native notification credits")
        XCTAssertLessThanOrEqual(stalledStatistics["bodyBytes"]!, stalledStatistics["capacity"]! * 4080)
        let begin = ProcessInfo.processInfo.systemUptime
        let request = CUUserChange(); request.userIdentifier = expected[0].userIdentifier; request.operationIdentifier = UUID().uuidString
        let result = try await XCTUnwrap(read).call(request)
        XCTAssertEqual(result.revision, expected[0].revision)
        slowProbeMillis = (ProcessInfo.processInfo.systemUptime - begin) * 1000
        XCTAssertEqual(arrivals.count, expected.count, "Stalled consumer must not have consumed notifications")
    }
    func disconnect() async throws {
        if let users { var policy = Self.policy; policy.automaticRefresh = false; try users.configureLiveUsers(policy) }
        reading?.cancel(); reading = nil
        await transport.close(); subscription = nil; disconnected = true
    }
    func reconnect(_ expected: [FanoutState]) async throws {
        try await transport.connect(timeout: .seconds(15))
        if slow { try await prepareSlow(expected); consume() }
        else { try users?.configureLiveUsers(Self.policy) }
        try await assertReached(expected)
        try await eventually { await self.transport.activeSubscriptionCount == 1 }
        requests = try await transport.submittedRequestCount()
        disconnected = false
    }
    func close() async { users?.stopObserving(); reading?.cancel(); await transport.close() }
    func report() async throws -> [String: Any] {
        ["index": index, "slow": slow, "arrivals": arrivals, "errors": errors,
         "stableObjectIdentity": slow || values.map(ObjectIdentifier.init) == identities,
         "requestsAtFinalReadiness": requests, "requestsAtEnd": try await transport.submittedRequestCount(),
         "rpcWhileNotificationStalledMillis": slowProbeMillis, "stalledNativeStatistics": stalledStatistics]
    }
}

@MainActor private func eventually(_ predicate: @MainActor () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(45)
    while !(await predicate()) && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard await predicate() else { throw NSError(domain: "Fanout convergence timeout", code: 1) }
}

/// Opt-in independent-process driver; each shard stays below the native owner limit.
@MainActor final class NativeFanoutUsersTests: XCTestCase {
    func testFanoutWorker() async throws {
        guard let path = ProcessInfo.processInfo.environment["CU_FANOUT_CONFIG"] else { throw XCTSkip("Use qualify-user-fanout.py") }
        let config = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any])
        let directory = URL(fileURLWithPath: config["directory"] as! String)
        let role = config["role"] as! String
        func write(_ name: String, _ object: Any) throws {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: directory.appendingPathComponent(name), options: .atomic)
        }
        func wait(_ name: String) async throws -> Data {
            let url = directory.appendingPathComponent(name), deadline = ContinuousClock.now + .seconds(240)
            while !FileManager.default.fileExists(atPath: url.path) && ContinuousClock.now < deadline {
                if FileManager.default.fileExists(atPath: directory.appendingPathComponent("abort").path) { throw NSError(domain: "Fanout controller aborted", code: 2) }
                try await Task.sleep(for: .milliseconds(20))
            }
            return try Data(contentsOf: url)
        }
        func expected(_ name: String) async throws -> [FanoutState] {
            try JSONDecoder().decode([FanoutState].self, from: await wait(name))
        }
        func connection() -> ConnectClient {
            ConnectClient(configuration: ConnectConfiguration(peer: config["peer"] as! String, serverName: "localhost",
                certificate: config["certificate"] as! String, privateKey: config["private_key"] as! String,
                trustedCertificate: config["trusted_certificate"] as! String, capacity: 4))
        }
        if role == "writer" {
            // A refused open owns no native handle. Closing an admission retry
            // must cancel it and leave the actor reusable, without a peer request.
            let invalid = ConnectClient(configuration: ConnectConfiguration(peer: config["peer"] as! String, serverName: "localhost",
                certificate: directory.appendingPathComponent("absent-certificate.der").path,
                privateKey: directory.appendingPathComponent("absent-key.der").path,
                trustedCertificate: config["trusted_certificate"] as! String))
            let pending = Task { try await invalid.connect(timeout: .seconds(2)) }
            try await Task.sleep(for: .milliseconds(30)); await invalid.close()
            do { try await pending.value; XCTFail("Closing local admission must cancel the open") }
            catch { XCTAssertEqual(error as? ConnectError, .connectionFailed) }
            do { try await invalid.connect(timeout: .milliseconds(10)); XCTFail("Invalid identities must not create an owner") }
            catch { XCTAssertEqual(error as? ConnectError, .invalidConfiguration) }
            await invalid.close()
            try write("admission-cancellation.json", ["closedBeforeAdmission": true, "boundedInvalidOpen": true])
            let transport = connection()
            do {
                try await transport.connect(timeout: .seconds(15))
                let create = try ObjectBinding(transport: transport, operation: 3, request: CUUserChange(), result: CULiveUserState(), profile: .stateV2)
                let update = try ObjectBinding(transport: transport, operation: 5, request: CUUserChange(), result: CULiveUserState(), profile: .stateV2)
                try await create.prepare(); try await update.prepare()
                let prefix = config["prefix"] as! String
                var states: [FanoutState] = [], writes: [[String: Any]] = []
                for index in 0..<3 {
                    let request = CUUserChange(); request.name = prefix + ":user" + String(index); request.operationIdentifier = UUID().uuidString
                    let result = try await create.call(request); XCTAssertEqual(result.outcome, "created"); states.append(FanoutState(result))
                }
                func save(_ name: String) throws { try JSONEncoder().encode(states).write(to: directory.appendingPathComponent(name), options: .atomic) }
                try save("seed.json")
                var sequence = 0
                for (gate, result, count) in [("start", "baseline.json", 9), ("burst-go", "burstA.json", 192),
                                               ("burstB-go", "burstB.json", 192), ("offline-go", "offline.json", 3), ("final-go", "final.json", 9)] {
                    _ = try await wait(gate)
                    let interval = result.hasPrefix("burst") ? (config["writeIntervalMillis"] as? Double ?? 0) / 1000 : 0
                    let phaseStart = ProcessInfo.processInfo.systemUptime
                    for ordinal in 0..<count {
                        let offeredAt = phaseStart + Double(ordinal) * interval
                        let delay = offeredAt - ProcessInfo.processInfo.systemUptime
                        if interval > 0 && delay > 0 { try await Task.sleep(for: .nanoseconds(Int64(delay * 1_000_000_000))) }
                        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("abort").path) { throw NSError(domain: "Fanout controller aborted", code: 2) }
                        let index = sequence % 3; sequence += 1
                        let request = CUUserChange(); request.userIdentifier = states[index].userIdentifier
                        request.expectedRevision = states[index].revision; request.operationIdentifier = UUID().uuidString
                        request.name = prefix + ":user" + String(index) + ":r" + String(sequence) + ":" + String(repeating: "x", count: 800)
                        let begin = ProcessInfo.processInfo.systemUptime
                        let response = try await update.call(request, timeout: .seconds(30))
                        XCTAssertEqual(response.outcome, "updated"); XCTAssertEqual(response.revision, request.expectedRevision + 1)
                        states[index] = FanoutState(response)
                        writes.append(["user": response.userIdentifier, "revision": response.revision, "sentAt": begin,
                                       "replyAt": ProcessInfo.processInfo.systemUptime, "phase": result,
                                       "offeredAt": interval > 0 ? offeredAt : begin])
                        if result == "baseline.json" { try await Task.sleep(for: .milliseconds(100)) }
                    }
                    try save(result)
                }
                try write("writer-result.json", ["writes": writes, "count": writes.count])
                _ = try await wait("stop")
                await transport.close(); try write("writer-done.json", ["closed": true])
            } catch { await transport.close(); try? write("writer-error.json", ["error": String(describing: error)]); throw error }
            return
        }
        let shard = config["shard"] as! Int, start = config["start"] as! Int, count = config["count"] as! Int
        let total = config["total"] as! Int, slowCount = config["slow"] as! Int
        var observers: [FanoutObserver] = []
        do {
            let seed = try await expected("seed.json")
            for index in start..<(start + count) {
                let observer = FanoutObserver(index: index, transport: connection(), slow: index >= total - slowCount)
                observers.append(observer); try await observer.setUp(seed)
            }
            try write("ready-\(shard).json", ["observers": count])
            for phase in ["baseline", "burstA", "burstB"] {
                let current = try await expected(phase + ".json")
                for observer in observers where !observer.slow { try await observer.assertReached(current) }
                if phase == "burstB" {
                    for observer in observers {
                        let submitted = try await observer.transport.submittedRequestCount()
                        XCTAssertEqual(submitted, observer.requests, "Watching bursts must issue no reads or renewals")
                    }
                    for observer in observers where observer.slow { try await observer.probeWhileStalled(current) }
                }
                try write(phase + "-\(shard).json", ["fastConverged": true])
            }
            _ = try await wait("resume")
            let burst = try await expected("burstB.json")
            for observer in observers {
                if observer.slow && observer.index == total - slowCount {
                    observer.consume(); try await observer.assertReached(burst)
                } else if observer.slow || observer.index % 4 == 0 { try await observer.disconnect() }
            }
            try write("offline-ready-\(shard).json", ["ready": true])
            let offline = try await expected("offline.json")
            for observer in observers where !observer.disconnected { try await observer.assertReached(offline) }
            _ = try await wait("reconnect")
            for observer in observers where observer.disconnected { try await observer.reconnect(offline) }
            for observer in observers { observer.requests = try await observer.transport.submittedRequestCount() }
            try write("reconnected-\(shard).json", ["ready": true])
            let final = try await expected("final.json")
            for observer in observers { try await observer.assertReached(final) }
            try await Task.sleep(for: .seconds(2))
            var results: [[String: Any]] = []
            for observer in observers {
                let result = try await observer.report()
                XCTAssertEqual(result["requestsAtFinalReadiness"] as? UInt64, result["requestsAtEnd"] as? UInt64, "Final push and idle must submit no requests")
                results.append(result)
            }
            try write("result-\(shard).json", ["observers": results, "converged": true])
            for observer in observers { await observer.close() }
            try write("done-\(shard).json", ["closed": true])
        } catch {
            for observer in observers { await observer.close() }
            try? write("error-\(shard).json", ["error": String(describing: error)]); throw error
        }
    }
}
