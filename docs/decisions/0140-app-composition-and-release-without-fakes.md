# ADR 0140: App composition, and Release builds without StarlingFakes

- Status: Accepted (code merged on main; status updated 2026-10-06)
- Date: 2026-09-30
- Owner: H (App features)

## Context

Lane H builds the Phase 1 journey before lanes E1, E2, F, and G merge, so Debug builds need `StarlingFakes` (`ScriptedDownService`, `ScriptedPairingSession`, `InMemoryPairedPeerStore`). `StarlingFakes` also contains `InsecurePSIStub` and allow-all doubles, and the lane plan says Release builds must not ship it.

SwiftPM cannot make a product dependency conditional on the build configuration: `TargetDependencyCondition` offers `.when(platforms:)` and `.when(traits:)` only (checked in the Xcode 27.0 `PackageDescription.swiftinterface`). XcodeGen has no per-configuration dependency either.

Wrapping every `import StarlingFakes` in `#if DEBUG` is necessary but was measured to be insufficient: a Release build for the iOS 27 Simulator still contained `ScriptedDownService`, `InsecurePSIStub`, and 686 other `StarlingFakes` symbols (`nm Starling.app/Starling`), because Xcode links the product's object file and the linker keeps Swift conformance records alive.

View models also need unit tests. A simulator test target would make every test run boot a simulator.

## Decision

1. **View models live in `App/Features`**, a SwiftPM package (`StarlingFeatures`) owned by lane H that depends on `StarlingCore` only and never imports SwiftUI, UIKit, or `StarlingFakes`. Its tests run with `swift test` on the Mac (`Tools/test-all.sh App/Features`). SwiftUI views stay in `App/Sources`.
2. **`AppServices` lists what the features are built from.** Debug builds assemble it in `DebugHarness` (real model and rules file, fakes for unmerged lanes). Release builds assemble it from real implementations only; a service that does not exist yet is `nil`, and its screen says "isn't in this build yet" instead of running on a fake.
3. **Release builds do not link `StarlingFakes`.** Every import stays inside `#if DEBUG`, and `App/project.yml` sets `EXCLUDED_SOURCE_FILE_NAMES = StarlingFakes.o` for the Release configuration of the app target. Xcode documents this setting as excluding matching files "when processing the files in the target's build phases"; measured result: the object leaves the Release link file list and `nm` finds 0 `StarlingFakes` symbols. Any Release code that referenced a fake now fails to link, which turns the rule into a build error.
4. **Nearby (the Phase 0 LocalP2P spike) compiles in Debug only.** It is unauthenticated, unencrypted, and uses the allow-all policy from `StarlingFakes`. Model Bench has no fakes and stays in both configurations.

Verification command (also requested for CI in `docs/requests/H.md`):

```
xcodebuild build -project App/Starling.xcodeproj -scheme Starling -configuration Release \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO -derivedDataPath build
nm build/Build/Products/Release-iphonesimulator/Starling.app/Starling | grep -c StarlingFakes   # expect 0
```

## Consequences

- The exclusion relies on the product's object file being named `StarlingFakes.o`, which is how Xcode 27 links static package products today. If Xcode changes that, the `nm` check catches it; a CI job running it is the durable guard.
- Debug builds are the only builds that run the full journey until E1, E2, and F merge. A Release (TestFlight) build before then shows onboarding, rules, and Developer only.
- `Tools/test-all.sh` does not scan `App/`, so `StarlingFeatures` tests are not in CI until the Orchestrator adds it (requested).
- When a lane merges, wiring it in means filling one `AppServices` field in `LiveServices.swift` (Release) and replacing the fake in `DebugServices.swift`.

## Sources

- Xcode build settings reference, `EXCLUDED_SOURCE_FILE_NAMES`: https://developer.apple.com/documentation/xcode/build-settings-reference
- PackageDescription `TargetDependencyCondition`: https://developer.apple.com/documentation/packagedescription/targetdependencycondition
- Measurements: `nm` on Release simulator builds of this branch, before and after the setting (688 and 0 matching symbols).
