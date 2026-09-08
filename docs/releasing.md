# Release Keel

Public releases use Developer ID signing and Apple notarization. The local development certificate used by `Scripts/build.sh` is not a substitute.

## Maintainer setup

Install a Developer ID Application certificate and its private key in the signing Mac's keychain. Creating that certificate requires the appropriate access to an Apple Developer Program team. Do not commit or upload the certificate's private key to a pull request.

Configure a `notarytool` keychain profile locally using `xcrun notarytool store-credentials`. Follow its interactive prompts or Apple's documented App Store Connect API-key method. Do not put an Apple password or API private key in a command recorded in an issue, a shell script, or this repository.

The packaging script takes the signing identity name in `KEEL_DEVELOPER_ID` and the keychain profile name in `KEEL_NOTARY_PROFILE`. These are references to local credentials, not the credentials themselves.

## Prepare the source

1. Review code and asset rights. Resolve any pending image notices before publication.
2. Update the version/build number and release notes. State the supported macOS version, architecture, and known limitations.
3. Run `Scripts/verify.sh` and the hosted CI workflow. Investigate failures rather than bypassing them.
4. Commit the exact source. The packaging script refuses an uncommitted worktree.

## Package

With the two environment variables configured locally, run:

```sh
Scripts/package-release.sh
```

The script creates an isolated temporary directory, builds the arm64 app, signs it with a secure timestamp and hardened runtime, submits it to Apple, and staples its ticket. It then creates a compressed disk image with an Applications shortcut, signs and notarizes that image, and staples and validates its ticket. Both notarization submissions must return Accepted. The final Gatekeeper assessment must pass.

The script outputs a DMG and a SHA-256 checksum. Keep the signing and notarization logs private. No step publishes to GitHub automatically.

## Test the actual download

Use a separate Mac or clean account to download the candidate, open the disk image, copy Keel to Applications, and launch it without disabling Gatekeeper. Verify the icon, minimum OS behaviour, browsing, queue/Finish/Undo, a download and its permission prompt, and basic keyboard operation. Test replacing an earlier installation without losing its profile. Confirm the downloaded checksum and installed build provenance.

Do not describe a locally built or unquarantined copy as proof of the download/install path. Do not advertise Intel or older macOS compatibility without testing it.

## Publish

Create a GitHub pre-release for the first beta. Attach only the verified DMG and checksum. Link the exact release from the README and use its tag in reproduction instructions. Confirm the release asset, source archive, README images, issue forms, and security-reporting link from a logged-out session.

Updates are manual for the first release. A Homebrew cask or an automatic updater must refer to verified release assets and have its own update test before being advertised.

Apple's [notarization documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) describes the signing, hardened runtime, timestamp, and ticket requirements.
