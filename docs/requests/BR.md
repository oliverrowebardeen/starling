# Requests from lane BR (Brand and app icon)

## 1. Link StarlingDesign into the app (lane H, `App/project.yml`)

**What.** Add the new package and product to the app target:

```yaml
packages:
  StarlingDesign:
    path: ../Packages/StarlingDesign
targets:
  Starling:
    dependencies:
      - package: StarlingDesign
        product: StarlingDesign
```

Then lane H decides where `StatusMark(state:)` appears (the Down screen is the obvious place) and maps the v1 `DownEvent` to `MarkState`:

| `DownEvent` | `MarkState` |
|---|---|
| no intent | `.idle` |
| `.checking(friends:)` | `.searching` |
| `.matched` | `.match` (the mark then rests as the logo) |
| `.ended` | `.noMatch`, then `.idle` |

**Privacy caution for `.negotiating`.** Do not drive `.negotiating` from a PSI overlap or any other step that only happens when a friend's intent overlaps yours. The owner would see the mark change and learn that someone is down at an overlapping time even if the exchange then fails, which is the one-sided reveal ARCHITECTURE section 7 rules out. v1 `DownEvent` has no such signal, which is correct. Leave `.negotiating` unused unless lanes F and H agree on a signal that fires the same way whether or not anyone overlaps.

**Why.** The mark is built and tested (`Packages/StarlingDesign`, ADR 0172), but `App/` belongs to lane H, so BR cannot link it. Until it is linked, the owner can only see the mark through Xcode Previews.

**Meanwhile.** Nothing blocked. The device checklist uses Xcode Previews on a phone.

## 2. Re-apply the icon wiring if it conflicts with PR #15 (Orchestrator)

Commit `chore(app): use Starling.icon as the app icon` touches only `App/project.yml`: one source entry (`Resources/Starling.icon`, `type: file`, `buildPhase: resources`) and one build setting (`ASSETCATALOG_COMPILER_APPICON_NAME: Starling`). If lane H's restructure moves the target, re-add those two pieces to the app target. ADR 0170 explains both.

## 3. Orchestrator-owned docs

- `docs/decisions/README.md`: rows for ADRs 0170, 0171, and 0172.
- `docs/ARCHITECTURE.md` section 1: `StarlingDesign` as a UI package next to the app, depending on nothing in StarlingKit.

## 4. For the owner, optional

The Mac has XcodeGen 2.44.1. Version 2.45.1 and later recognize `.icon` bundles on their own (CI already gets 2.46.0 from Homebrew). The spec works with both, so upgrading only matters if someone later drops the explicit `type` and `buildPhase`.
