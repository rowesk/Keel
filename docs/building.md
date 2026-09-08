# Build Keel from source

These instructions describe the current pre-release development build. A source archive is not an installable Mac app.

## Requirements

- macOS 26 or later. Apple silicon is the tested architecture.
- An active Apple toolchain with Swift 6.2 or later and the macOS 26 SDK.
- Git, Python 3, and an Apple Development signing certificate in your keychain for the app bundle.

Check `swift --version` and `xcrun --show-sdk-version`. If you have multiple Xcode installations, select the intended toolchain before building.

## Get the source

Clone the public source:

```sh
git clone https://github.com/rowesk/Keel.git
cd Keel
```

The default branch contains current development. Use a release tag when reproducing a particular published build.

## Build a signed app

```sh
Scripts/build.sh
```

The script creates a temporary build directory outside the checkout, compiles the release, packages resources, records build provenance, and verifies the app signature. Its final output line is the path to `Keel.app`. Open that bundle when you are ready to try it. Keep a backup of any existing Keel installation before replacing it.

To choose an output location:

```sh
KEEL_BUILD_ROOT="$(mktemp -d /tmp/keel-build.XXXXXX)" Scripts/build.sh
```

The script selects an Apple Development identity from your keychain. Set `KEEL_SIGN_IDENTITY` to choose a different development identity if needed. It refuses ad-hoc signing. You can compile the executable with `swift build` without that certificate, but the executable alone is not the supported sandboxed app bundle.

This build path is for local development. It does not produce a notarized public installer. Do not distribute it as the public release or tell users to disable Gatekeeper.

## Verify changes

Run the focused tests for the module you changed, then the complete gate before submitting a candidate:

```sh
swift test --filter KeelWebTests
Scripts/verify.sh
```

The gate runs tests and snapshot comparisons, compiles with warnings as errors, builds a development-signed app, and checks whitespace. It disables foreground tests and snapshot recording. A signing certificate is required for its build step.

Snapshot baselines use the en_GB locale and Europe/London time zone. Hosted CI sets these only on its disposable runner. Keel bundles Palace Script for the Home wordmark, so local and hosted runs use the same font. Inspect a mismatch before deciding whether a visual change is intended. Never record new baselines simply to make a check pass, and do not change your Mac's global settings just to run tests.

## Where the code lives

| Module | Responsibility |
| --- | --- |
| `KeelFoundation` | Shared browser values and policies |
| `KeelStore` | SQLite storage and transactions |
| `KeelCoordinator` | Page, queue, Undo, and resume transitions |
| `KeelWeb` | WebKit navigation, downloads, and page lifetime |
| `KeelUI` | SwiftUI screens and visual design |
| `KeelApp` | macOS window, menus, keyboard commands, and integration |

Read [the domain vocabulary](../CONTEXT.md) before changing page or queue behaviour.
