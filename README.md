# Catalyst Users for Swift

Native CUUser and MainActor CUUsers use our Magritte Swift port and the existing
caller-owned ConnectClient. The Fabric adopts the original User after GemStone
confirms commit, keeps a scoped identity cache, receives pushed changes and recovers
creation receipts after reconnect.

```swift
let users = try CUUsers(connect: connectedTransport)
let user = CUUser(name: "Ada")
users.onError = { user, error in /* Present or record the error. */ }
users.createUser(user) // Optional one-shot operation; ignoring it does not cancel execution.
user.name = "Ada Lovelace" // Preserved if confirmation is still in flight.
let cached = try await users.getUser(named: "Ada Lovelace")
```

Observe `objectWillChange`, `replica` and `lastError`. Name edits are submitted by
a bounded per-connection coordinator. Configure CULiveUserPolicy live, disable its
automaticRefresh for manual `synchronizeNow`, and use `resolveConflict` explicitly
for conflicts or uncertain updates. A read never authorizes an uncertain write's
replay. `stopObserving` stops the shared scope; the host closes the transport.
Swift CUUsers instances sharing a ConnectClient share policy/cache. Keep User
instances while observed. The host owns reconnect; the Fabric renegotiates itself.

Enable server operations 3/4/5/6/7/8/9/65534 with an authoritative Users binding. Current
creation/update permissions are peer scoped, without account/tenant authorization.
Exact name lookup returns nil for absence and refuses ambiguous matches. Managed
super-user state is server owned. Magritte metadata supports client UI work;
no UI generator is delivered here. Updates arrive on the connection’s server-initiated reliable QUIC notification
stream after a single subscription setup. Idle clients send no receive/renew RPCs.

For legacy operations 1/2 call `prepare()` then `createUserSnapshot` or
`getUserSnapshot(named:)`; prepare again after reconnect. These preserve the
original scalar schema and fresh-result semantics.

Build the combined macOS/iOS package:

```sh
python3 /path/to/CatalystConnectSwift/scripts/build-apple.py \
  --transport /path/to/CatalystConnect --users /path/to/CatalystUsersSwift \
  --build-dir /path/to/native-build --output /path/to/new-ApplePackage
```

The generated package supplies native archive linking. The repository manifest is
the source-development form. See the Users service repository's
`docs/Connect-CreateUser.md` and `scripts/qualify-platform-users.py` for protocol,
recovery limits, installation and native qualification. Physical-device execution,
graph/4 transfer and production account security remain future work.

GemStone authorities deliver changes after commit. GT authorities deliver after
volatile Runtime finalization, without claiming persistence/rollback. The feed
coalesces finalized state by User identity and publishes over the persistent QUIC
notification stream, with bounded backpressure and explicit session-scoped revocation. Reconnect resubscribes/resnapshots; unknown mutations are
never automatically replayed. See service documentation for configurable feed
limits and the dedicated `--push-only --authority gt` native qualification.

## License

This repository is licensed under the [Catalyst Developer License](LICENSE).

Each developer using Catalyst for development needs an active
BenjaVision-Catalyst subscription: **$5 per month, billed annually at $60 per
developer**, including access to the BenjaVision-Catalyst repository. New products,
updates, bug fixes, and recompilation require active developer subscriptions.
Automated build machines do not need separate subscriptions.

Products lawfully built during active subscriptions may continue to be used,
hosted, sold, and distributed indefinitely without runtime royalties. Customers
and operators do not need subscriptions solely to use or distribute those builds.
Commercial and proprietary products are permitted; this license does not require
you to publish your own source code.

Existing license grants and separately licensed third-party material remain
unaffected. See [LICENSE](LICENSE) for the complete terms.
