import Foundation
import CatalystConnect
import CatalystConnectObjects

public struct CULiveUserPolicy: Sendable {
    public var maximumObjects = 64
    public var refreshInterval: Duration = .seconds(1)
    public var automaticRefresh = true
    public init() {}
}
public enum CUUserFabricError: Error, Equatable {
    case capacity, refused, conflict, uncertain, incompatibleState, stopped
}
private final class WeakUser { weak var value: CUUser?; init(_ value: CUUser) { self.value = value } }
@MainActor private final class WeakContext { weak var value: CULiveUsersContext?; init(_ value: CULiveUsersContext) { self.value = value } }

/// One cache and refresh owner per caller-owned transport. No new connection, Runtime or transaction manager.
@MainActor internal final class CULiveUsersContext {
    private static var contexts: [ObjectIdentifier: WeakContext] = [:]
    static func shared(_ transport: ConnectClient, policy: CULiveUserPolicy) throws -> CULiveUsersContext {
        contexts = contexts.filter { $0.value.value != nil }
        let key = ObjectIdentifier(transport)
        if let existing = contexts[key]?.value { return existing }
        guard (1...256).contains(policy.maximumObjects), policy.refreshInterval >= .milliseconds(20) else { throw CUUserFabricError.capacity }
        let result = try CULiveUsersContext(transport, policy: policy)
        contexts[key] = WeakContext(result); return result
    }
    private let transport: ConnectClient
    private(set) var policy: CULiveUserPolicy
    private let create, read, update, recover, subscribe, receive, unsubscribe: ObjectBinding<CUUserChange, CULiveUserState>
    private var objects: [ObjectIdentifier: WeakUser] = [:]
    private var identities: [String: WeakUser] = [:]
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var preparation: Task<Void, Error>?
    private var preparedSession: ConnectSession?
    private var feedKey = UUID().uuidString
    private var subscriptions = Set<String>(), attemptedRecoveries = Set<String>()
    private var receiving: Task<Void, Never>?
    private var receiveGeneration = UUID()
    private var writesInFlight = Set<ObjectIdentifier>()
    private var deferredStates: [ObjectIdentifier: CULiveUserState] = [:]
    private var timer: Task<Void, Never>?
    private var synchronizing = false, stopped = false
    var onError: ((CUUser, Error) -> Void)?
    private init(_ transport: ConnectClient, policy: CULiveUserPolicy) throws {
        self.transport = transport; self.policy = policy
        func binding(_ code: UInt16) throws -> ObjectBinding<CUUserChange, CULiveUserState> {
            try ObjectBinding(transport: transport, operation: code, request: CUUserChange(), result: CULiveUserState(), profile: .stateV2)
        }
        create = try binding(3); read = try binding(4); update = try binding(5); recover = try binding(6)
        subscribe = try binding(7); receive = try binding(8); unsubscribe = try binding(9)
    }
    private func activate() {
        guard timer == nil, !stopped, policy.automaticRefresh else { return }
        let interval = policy.refreshInterval
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                if let context = self { await context.synchronize(automatic: true) } else { return }
            }
        }
    }
    private func ensureReady() async throws {
        guard !stopped else { throw CUUserFabricError.stopped }
        let session = try await transport.currentSession()
        if preparedSession == session { return }
        if let preparation { return try await preparation.value }
        let task = Task { @MainActor [self] in
            try await create.prepare(); try await read.prepare(); try await update.prepare(); try await recover.prepare()
            guard try await transport.currentSession() == session else { throw ConnectError.notReady }
            try await subscribe.prepare(); try await receive.prepare(); try await unsubscribe.prepare()
            resetFeed()
            preparedSession = session
        }
        preparation = task
        defer { preparation = nil }
        try await task.value
    }
    private func track(_ user: CUUser) throws {
        objects = objects.filter { $0.value.value != nil }; identities = identities.filter { $0.value.value != nil }
        if objects[ObjectIdentifier(user)] == nil {
            guard objects.count < policy.maximumObjects else { throw CUUserFabricError.capacity }
            objects[ObjectIdentifier(user)] = WeakUser(user)
        }
        user.context = self
    }
    private func report(_ user: CUUser, _ error: Error) {
        let text = String(describing: error)
        if user.lastError != text {
            user.lastError = text
            if let onError { onError(user, error) }
            else { NSLog("Catalyst Users Fabric: %@", text) }
        }
    }
    @discardableResult private func install(_ state: CULiveUserState, into user: CUUser, sent: UInt64? = nil) throws -> CUUser {
        guard !stopped, user.context === self, !state.userIdentifier.isEmpty, state.revision > 0,
              user.replica.identifier.isEmpty || user.replica.identifier == state.userIdentifier,
              state.revision >= user.replica.revision else { throw CUUserFabricError.incompatibleState }
        if let existing = identities[state.userIdentifier]?.value, existing !== user { throw CUUserFabricError.incompatibleState }
        user.applying = true
        user.acceptedName = state.name
        let replace = user.replica.accept(identifier: state.userIdentifier, revision: state.revision, sentSequence: sent)
        if replace { user.name = state.name }
        user.isSuperUser = state.isSuperUser
        user.applying = false
        identities[state.userIdentifier] = WeakUser(user)
        if user.replica.phase == .conflict { report(user, CUUserFabricError.conflict) }
        else { user.lastError = nil }
        user.objectWillChange.send()
        return user
    }
    func createUser(_ user: CUUser) -> ObjectOperation<CUUser> {
        let operation = ObjectOperation<CUUser>()
        do {
            guard user.context == nil, user.replica.identifier.isEmpty, !user.isSuperUser else { throw CUUserFabricError.refused }
            _ = try ObjectSchema(exemplar: CUUser()).encode(user)
            try track(user); activate()
            user.creationKey = UUID().uuidString.lowercased(); user.creationName = user.name
            user.creationSequence = user.replica.editSequence; user.replica.transition(.creating)
            let change = CUUserChange(); change.operationIdentifier = user.creationKey; change.name = user.creationName
            let key = UUID()
            jobs[key] = Task { @MainActor [self, user, operation] in
                defer { jobs.removeValue(forKey: key) }
                do {
                    try await ensureReady()
                    let state = try await create.call(change)
                    guard state.outcome == "created" else { user.replica.transition(.refused); throw CUUserFabricError.refused }
                    try install(state, into: user, sent: user.creationSequence)
                    operation.finish(.success(user))
                } catch {
                    if user.replica.phase != .refused { user.replica.transition(Self.definitelyRefused(error) ? .refused : .uncertain) }
                    report(user, error); operation.finish(.failure(error))
                }
            }
        } catch { report(user, error); operation.finish(.failure(error)) }
        return operation
    }
    func getUser(named name: String) async throws -> CUUser? {
        activate(); try await ensureReady()
        let change = CUUserChange(); change.name = name; change.operationIdentifier = UUID().uuidString
        let state = try await read.call(change)
        if state.outcome == "notFound" { return nil }
        guard state.outcome == "current" else { throw CUUserFabricError.refused }
        let user = identities[state.userIdentifier]?.value ?? CUUser()
        try track(user); return try install(state, into: user)
    }
    func synchronize(automatic: Bool = false) async {
        guard !synchronizing, !stopped else { return }
        synchronizing = true; defer { synchronizing = false }
        let current = objects.values.compactMap(\.value)
        guard !current.isEmpty else {
            if policy.automaticRefresh, preparedSession != nil { await maintainSubscriptions() }
            return
        }
        do { try await ensureReady() }
        catch {
            preparedSession = nil
            for user in current where user.replica.phase == .live { user.replica.transition(.stale) }
            return
        }
        for user in current {
            guard !stopped, user.context === self, user.replica.phase != .creating, user.replica.phase != .refused else { continue }
            do {
                let change = CUUserChange(); change.operationIdentifier = UUID().uuidString
                if user.replica.identifier.isEmpty {
                    guard !user.creationKey.isEmpty, !automatic || !attemptedRecoveries.contains(user.creationKey) else { continue }
                    attemptedRecoveries.insert(user.creationKey)
                    change.operationIdentifier = user.creationKey
                    let state = try await recover.call(change)
                    if state.outcome == "created" { try install(state, into: user, sent: user.creationSequence) }
                    continue // Unknown receipt is never proof of nonexecution and never authorizes recreation.
                }
                change.userIdentifier = user.replica.identifier
                if user.replica.hasEdits && (user.replica.phase == .live || user.replica.phase == .stale) {
                    change.name = user.name; change.expectedRevision = user.replica.editBase
                    let sequence = user.replica.editSequence
                    let token = ObjectIdentifier(user); writesInFlight.insert(token)
                    defer {
                        writesInFlight.remove(token)
                        if let deferred = deferredStates.removeValue(forKey: token), deferred.revision > user.replica.revision { try? install(deferred, into: user) }
                    }
                    let state = try await update.call(change)
                    if state.outcome == "updated" { try install(state, into: user, sent: sequence) }
                    else if state.outcome == "conflict" { try install(state, into: user); user.replica.transition(.conflict); report(user, CUUserFabricError.conflict) }
                    else { user.replica.transition(.refused); report(user, CUUserFabricError.refused) }
                } else {
                    if automatic { continue } // Clean replicas receive state from the authority; no periodic read.
                    let state = try await read.call(change)
                    if state.outcome == "current" { try install(state, into: user) }
                    else if state.outcome == "notFound" { user.replica.transition(.notFound) }
                    else { user.replica.transition(.refused); report(user, CUUserFabricError.refused) }
                }
            } catch {
                preparedSession = nil; user.replica.transition(.uncertain); report(user, error)
            }
        }
        if policy.automaticRefresh { await maintainSubscriptions() }
    }
    private func resetFeed() {
        receiveGeneration = UUID(); receiving?.cancel(); receiving = nil
        feedKey = UUID().uuidString; subscriptions.removeAll(); attemptedRecoveries.removeAll()
    }
    private func maintainSubscriptions() async {
        let retained = Set(objects.values.compactMap(\.value).map { $0.replica.identifier }.filter { !$0.isEmpty })
        do {
            for identifier in subscriptions.subtracting(retained) {
                let change = CUUserChange(); change.operationIdentifier = feedKey; change.userIdentifier = identifier
                _ = try await unsubscribe.call(change); subscriptions.remove(identifier)
            }
            for identifier in retained.subtracting(subscriptions) {
                guard let user = identities[identifier]?.value else { continue }
                let change = CUUserChange(); change.operationIdentifier = feedKey; change.userIdentifier = identifier; change.expectedRevision = user.replica.revision
                subscriptions.insert(identifier) // Accept a push that races the watch RPC reply.
                let state = try await subscribe.call(change)
                guard state.outcome == "current" else { throw CUUserFabricError.refused }
                if state.revision >= user.replica.revision { try install(state, into: user) }
            }
            if subscriptions.isEmpty { resetFeed() } else { startReceiving() }
        } catch {
            for user in objects.values.compactMap(\.value) { report(user, error) }
            preparedSession = nil; resetFeed()
        }
    }
    private func startReceiving() {
        guard receiving == nil, !subscriptions.isEmpty, !stopped, policy.automaticRefresh else { return }
        let generation = receiveGeneration
        receiving = Task { @MainActor [weak self] in
            guard let context = self else { return }
            let change = CUUserChange(); change.operationIdentifier = context.feedKey
            var target: ConnectSubscription?
            do {
                let (subscription, setup) = try await context.receive.subscribe(change)
                target = subscription
                guard setup.outcome == "subscribed", generation == context.receiveGeneration, !Task.isCancelled else {
                    await context.transport.unsubscribe(subscription); return
                }
                for try await reply in subscription.events {
                    guard generation == context.receiveGeneration, !Task.isCancelled else { break }
                    let state = try context.receive.decodeNotification(reply)
                    guard state.outcome == "current" else { throw CUUserFabricError.incompatibleState }
                    guard context.subscriptions.contains(state.userIdentifier) else { continue } // A retired watch may have a queued event.
                    if let user = context.identities[state.userIdentifier]?.value {
                        let token = ObjectIdentifier(user)
                        if context.writesInFlight.contains(token) {
                            if state.revision > (context.deferredStates[token]?.revision ?? 0) { context.deferredStates[token] = state }
                        }
                        else if state.revision > user.replica.revision { try context.install(state, into: user) }
                    }
                }
            } catch {
                if generation == context.receiveGeneration {
                    context.preparedSession = nil; context.resetFeed()
                    for user in context.objects.values.compactMap(\.value) where user.replica.phase == .live { user.replica.transition(.stale) }
                }
            }
            if let target { await context.transport.unsubscribe(target) }

        }
    }
    func resolve(_ user: CUUser, keepLocal: Bool) {
        guard user.context === self else { return }
        if keepLocal { user.replica.rebaseLocal() }
        else { user.replica.acceptRemote(); user.applying = true; user.name = user.acceptedName; user.applying = false }
        user.lastError = nil
    }
    private static func definitelyRefused(_ error: Error) -> Bool {
        if let error = error as? ObjectBindingError {
            switch error { case .unknown: return false; default: return true }
        }
        if let error = error as? ConnectError {
            switch error { case .unknown: return false; default: return true }
        }
        return false
    }
    func configure(_ policy: CULiveUserPolicy) throws {
        let liveCount = objects.values.compactMap(\.value).count
        guard (max(1, liveCount)...256).contains(policy.maximumObjects), policy.refreshInterval >= .milliseconds(20) else { throw CUUserFabricError.capacity }
        self.policy = policy; timer?.cancel(); timer = nil
        if !policy.automaticRefresh { resetFeed() }
        if !stopped { activate() }
    }
    func stop() {
        stopped = true; timer?.cancel(); timer = nil; preparedSession = nil; resetFeed()
        for user in objects.values.compactMap(\.value) { user.replica.transition(.stale) }
        // Admitted jobs retain ownership until the existing Connect completion is terminal.
    }
}
