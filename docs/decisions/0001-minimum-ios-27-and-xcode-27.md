# ADR 0001: Minimum iOS 27, built with Xcode 27

- Status: Accepted
- Date: 2026-09-29
- Owner: Orchestrator

## Context

The brief proposes an iOS 27 minimum on the grounds that every Apple Intelligence iPhone runs iOS 27. Verification (see `docs/research/phase-0-verification.md`, Section 3.1):

- iOS 27 supports iPhone 11 and later, which includes every Apple Intelligence model (iPhone 15 Pro and later). The reasoning holds.
- iOS 27 brings APIs Starling wants: `LanguageModel` providers, `PrivateCloudComputeLanguageModel`, dynamic profiles, and the `Evaluations` framework.
- A reason the brief did not list: TN3213 says Wi-Fi Aware plus QUIC "is not supported prior to iOS 27."
- Xcode 27 (Swift 6.4, iOS 27 SDK) shipped 2026-09-14 and requires macOS Tahoe 26.6 or later on Apple silicon.
- The owner's Mac runs macOS 26.7 with **Xcode 26.1.1** (Swift 6.2.1, iOS 26.1 SDK). It cannot build for iOS 27 until Xcode 27 is installed.

## Decision

1. The app's deployment target is iOS 27.0. StarlingKit packages declare iOS 27.0 as well.
2. StarlingKit packages also declare **macOS 26.0**, so `swift test` runs on any macOS 26 host, including the owner's Mac and agents working on it. Code that needs macOS 27 or iOS 27 APIs uses `@available` and sits behind a protocol with a fake.
3. Manifests use `swift-tools-version: 6.2`, so they build with both Xcode 26.1.1 (local today) and Xcode 27 (CI and the owner once installed).
4. Xcode 27 is the canonical toolchain. CI builds with it (ADR 0007).

## Consequences

- **Owner action:** install Xcode 27 (Mac App Store or developer.apple.com) and the iOS 27 simulator runtime. Until then, iOS 27-only code is compile-checked only in CI.
- Friends on iOS 26 must update before they can install Starling. Acceptable for a TestFlight beta that starts after iOS 27 has been out for weeks.
- Code that calls iOS 26.4+ Foundation Models APIs (`tokenCount(for:)`) is guarded with `#if compiler(>=6.3)`, because the Swift 6.3 compiler shipped with the 26.4 SDKs. This is a proxy, and can be deleted once every environment runs Xcode 27.

## Sources

- iOS 27 compatible iPhones: https://support.apple.com/guide/iphone/iphone-models-compatible-with-ios-27-iphe3fa5df43/ios
- TN3213, "Enable peer-to-peer Wi-Fi": https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework
- `PrivateCloudComputeLanguageModel` (iOS 27.0+): https://developer.apple.com/documentation/foundationmodels/privatecloudcomputelanguagemodel
- `Evaluations` (iOS 27.0+, Xcode 27.0+): https://developer.apple.com/documentation/evaluations
- Xcode 27 requirements (secondary): https://mjtsai.com/blog/2026/09/15/xcode-27/
