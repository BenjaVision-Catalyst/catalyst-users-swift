# Catalyst Users for Swift

Catalyst Users for Swift is the planned native client for Apple applications
that need to work with Catalyst user accounts and personal controls. It aims
to expose Users operations through Swift while Connect handles communication.
This repository is currently a placeholder, with no Swift package or working
Users API yet.

## Planned role

- Native Swift values and a client interface for Catalyst Users.
- Account and personal-control operations owned by the Users service.
- Communication through the Swift Catalyst Connect implementation.

These are planned responsibilities. Swift APIs, supported Apple platforms,
network integration, and packaging have not been implemented here.

## Installation and development

Install the Catalyst development environment through
[BVC](https://github.com/BenjaVisionPro/bvc#install). There is no functional
package from this repository to install yet.

Read the [component design](https://github.com/BenjaVisionPro/catalyst-workspace/blob/main/Users/Catalyst-Users-Design.md)
for the intended scope and remaining integration work. Design documents describe
the direction; they do not establish a released implementation.

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
