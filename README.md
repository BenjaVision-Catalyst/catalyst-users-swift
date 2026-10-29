# Catalyst Users for Swift

A native `CUUser` model and `CUUsers` API using the generic description-derived
Connect object binding. The model owns its Magritte descriptions and native field
accessors. No Users-specific wire schema or codec exists.

Build the combined Apple package from the pinned Connect Swift repository:

```sh
python3 /path/to/CatalystConnectSwift/scripts/build-apple.py \
  --transport /path/to/CatalystConnect --users /path/to/CatalystUsersSwift \
  --build-dir /path/to/native-build --output /path/to/new-ApplePackage
```

Select the generated `CatalystUsers` product in Xcode/SwiftPM. Current slices cover
Apple Silicon macOS, arm64 iOS device and arm64 Simulator. The repository's own
manifest is the source-development form; the generated package supplies native
archive linking automatically.

```swift
import CatalystConnect
import CatalystUsers

// The host provisions and connects its mutually pinned ConnectClient.
let users = try CUUsers(connect: connect)
try await users.prepare()             // One startup description/service probe.
let result = try await users.createUser(CUUser(name: "Ada"))
// result is a new CUUser reconstructed from the committed server response.
```

The object API runs on MainActor; descriptions/native objects stay local, while
only bounded bytes cross the transport actor. `prepare()` must be repeated after
reconnect. The connection remains caller owned and must be closed during teardown.
No mutation is automatically replayed. The current server reports rollback and
other uncertain failed execution as `ObjectBindingError.unknown`; malformed results
and transport loss cannot produce a user value. Names and `isSuperUser` are the
current model, without stable tenant/account identifiers. Creating super users is
rejected by the server. Certificate trust does not grant account privileges.

The existing installed-description profile supports bounded String/Boolean/Int64
values and rejects unsupported validators, conditions, defaults and relations. It
is not full graph/4 exchange or remote code/class installation.

The same native Users XCTest suite passes on macOS and iOS Simulator against a
configured GemStone authority. A held insertion proves no result before commit;
an independent Gem reads the committed user after the result. Rollback, super-user
rejection, mismatched descriptions, stale readiness and explicit reconnect are
verified. See the service repository's `scripts/qualify-platform-users.py` and
`conformance/platform-create-user-2026-10-29.json`. Device execution is separate
from the successful unsigned arm64 device build.

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
