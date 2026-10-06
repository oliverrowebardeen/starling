# ADR 0007: CI on the GitHub `xcode-27` runner

- Status: Accepted
- Date: 2026-09-29
- Owner: Orchestrator

## Context

The brief asks for GitHub Actions on macOS, provided runner images carry the needed Xcode. As of 2026-09-29:

- `macos-26` (arm64, GA) carries Xcode 26.0.1 through 26.6 and iOS simulators up to 26.5. No iOS 27 SDK.
- `xcode-27` (arm64, **public preview**) runs macOS 27.0 with Xcode 27.0 (default), 27.1, and a 27.2 beta, plus iOS 27.0 to 27.2 SDKs and simulators.
- Neither image ships XcodeGen.
- The repository is private (ADR 0008). Private repositories spend Actions minutes, and macOS minutes are billed at a multiple of Linux minutes.

## Decision

1. CI runs on `runs-on: xcode-27` and pins Xcode 27.0 with `xcode-select`.
2. Jobs: (a) `Tools/test-all.sh` with warnings as errors; (b) install XcodeGen, generate the project, and `xcodebuild build` the app for the iOS 27 Simulator without signing.
3. Triggers: pull requests and pushes to `main` only, with concurrency cancellation, to limit minutes.
4. The local command, when CI is unavailable, is `Tools/test-all.sh` (works on macOS 26 with Xcode 26.1.1 or newer).

## Consequences

- A preview image can change or break; if it does, fall back to `macos-26` for package tests only and document it here.
- Device-only behavior (LocalP2P radios, Wi-Fi Aware, on-device model numbers) is never covered by CI. Each lane's device checklist covers it.
- If minutes run short on the private repo, CI can move to push-to-`main` only, or the repo can go public when the owner is ready.

## Amendment, 2026-09-30: a local gate while hosted CI does not run

From 22:53Z, GitHub Actions stopped starting jobs for this private repository, so every check failed with an empty log. No code change can fix this; it is an account setting, not the workflow.

Until CI runs again, nothing merges on a red check alone. Before each merge, the Orchestrator runs `Tools/local-gate.sh <branch>`. It merges the branch into the current `origin/main` in a throwaway worktree, then runs both CI jobs in the same order. The host is macOS 26.7 with Xcode 27.0 (27A266a), the same Xcode that CI pins. The PR gets a comment that names the commits tested and the result. Branch protection is not available on this private repo's plan, so nothing enforces the gate. It holds because the Orchestrator does the merging.

CI ran again from about 00:42Z on 2026-10-01. Main's first run after that, at 84461c5, passed both jobs, including the Release no-fakes step. CI on the pull request is the merge gate again. `Tools/local-gate.sh` stays in the repo for the next time hosted CI does not run, and for checking a branch against a newer main than its last CI run.

## Sources

- Runner images and labels: https://github.com/actions/runner-images
- `xcode-27` image contents: https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md
- Xcode 27 preview announcement: https://github.com/actions/runner-images/issues/14404
