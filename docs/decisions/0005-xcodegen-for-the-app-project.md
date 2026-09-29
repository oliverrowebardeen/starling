# ADR 0005: Generate the app project with XcodeGen

- Status: Accepted
- Date: 2026-09-29
- Owner: Orchestrator

## Context

Several lanes touch the app over time. A committed `.pbxproj` is a merge-conflict magnet, so the brief asks for XcodeGen or Tuist.

| | XcodeGen | Tuist |
|---|---|---|
| Spec | One YAML file | Swift manifests plus a CLI with its own project graph |
| Install | `brew install xcodegen`; already on the owner's Mac (2.44.1; 2.46.0 released 2026-07-16) | Separate installer and version manager |
| Scope | Generates a project, nothing else | Generation, caching, dependency management, cloud features |
| Fit | App target is thin; all logic lives in SwiftPM packages | Its extra features overlap with SwiftPM, which already owns our modules |

## Decision

Use XcodeGen. The spec is `App/project.yml`. The generated `App/Starling.xcodeproj` is gitignored and regenerated with `xcodegen generate --spec App/project.yml`. Packages are referenced as local SwiftPM packages from the spec.

## Consequences

- Lanes never edit a project file. Only lane H (App features) edits `App/project.yml`, and changes there are small.
- CI installs XcodeGen with Homebrew because the runner images do not ship it.
- If the app later needs multiple targets with complex shared settings, Tuist is the escape hatch; migrating a single YAML file is cheap.

## Sources

- XcodeGen releases: https://github.com/yonaskolb/XcodeGen/releases
- GitHub runner image software lists (no XcodeGen or Tuist): https://github.com/actions/runner-images
