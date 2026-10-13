# Third-party notices

Original SpaceHop additions and repository documentation are licensed under the root [MIT LICENSE](../LICENSE), copyright © 2026 fev0ks. Portions of the Spaces bookkeeping and synthetic Dock gesture mechanism are adapted from the following MIT-licensed projects. Their copyright notices and complete license texts must remain with redistributed copies.

| Project | Source used | Copyright | Local license |
| --- | --- | --- | --- |
| [jurplel/InstantSpaceSwitcher](https://github.com/jurplel/InstantSpaceSwitcher) | Commit [`f7616e42651b1ed8d81625e3640eceed6efa8018`](https://github.com/jurplel/InstantSpaceSwitcher/tree/f7616e42651b1ed8d81625e3640eceed6efa8018) | 2026 jurplel | [LICENSE-InstantSpaceSwitcher](LICENSE-InstantSpaceSwitcher) |
| [mmathys/noswoosh](https://github.com/mmathys/noswoosh) | Tag [`v1.7.6`](https://github.com/mmathys/noswoosh/tree/v1.7.6) | 2026 Max Mathys | [LICENSE-noswoosh](LICENSE-noswoosh) |

The implementation was adapted for the SpaceHop menu-bar app, verified transitions, current-Space window overview, per-display behavior, synthetic-event tagging and configurable gesture handling. No upstream project is bundled as an executable or external package.

The build script copies the root MIT license, both upstream license files and this notice into `SpaceHop.app/Contents/Resources/`.

Apple's frameworks and SDKs are not licensed by this repository's MIT license. AppKit, ApplicationServices, ScreenCaptureKit, ServiceManagement and the private SkyLight framework remain system components governed by Apple's applicable terms. No Apple framework binaries are redistributed. Loading a private symbol or emitting undocumented Dock events does not make those interfaces public or grant an exemption from Apple agreements or App Store review rules.
