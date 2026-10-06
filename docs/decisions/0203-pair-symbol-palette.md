# ADR 0203: Pair symbols from ten contrast-checked hue pairs

- Status: Accepted (code merged on main; status updated 2026-10-06)
- Date: 2026-10-01
- Owner: P15-A (Shell and IA)

## Context

DESIGN.md section 4 gives every friend a pair symbol: the Overlap mark in a color pair derived from their `PeerID`, from a curated set that keeps both shapes at least 3:1 against the background in light and dark. The owner's own symbol is the brand pair. The symbol is decorative; the code check at pairing verifies a friend (ADR 0101). The shell lane designs the palette.

## Decision

1. **Ten hue pairs**: teal, violet, orange, rose, green, magenta, cyan, brown, indigo, and olive, each with a darker shape A and a lighter shape B in light, and lighter shapes in dark. The brand blue pair is reserved for the owner. Values are in `StarlingDesign.PairPalette`.
2. **Contrast is tested.** Every shape of every pair, the brand pair included, is at least 3:1 (WCAG 2.x) against `#FAF9F6` in light and `#141418` in dark. The lowest is olive's light shape B at about 3.1.
3. **Choice.** The first eight bytes of the seed, read as a big-endian integer, modulo the number of pairs. The app passes the `PeerID`, which is SHA-256 of the friend's key, so those bytes are uniform and a peer would have to grind keys to choose a color. Grinding buys nothing, because the symbol is not a security signal.
4. **Accessibility.** The symbol is hidden from VoiceOver everywhere, because the friend's name is always beside it.
5. **Where it appears.** New's Ask row, the consent sheet's roster rows and recipient, proposal cards, Coming up, Friends, and You (the owner's own, in the brand pair). An unpaired person on a roster gets a question mark instead: their symbol would be chosen by whoever sent the roster.

## Consequences

- With ten pairs, two friends share a pair once a phone has a few friends (about 1 in 10 for any two). Names, `RosterLabels`' fingerprints, and the pairing code tell them apart; the symbol only helps recognition.
- Adding a pair later reshuffles every friend's symbol, because the choice is a modulo. Change the palette only with a migration note to testers.

## Sources

- DESIGN.md sections 2 and 4, `docs/brand/README.md` (tokens)
- WCAG 2.2, contrast (minimum) for non-text graphics, 1.4.11: https://www.w3.org/TR/WCAG22/#non-text-contrast
- `Packages/StarlingDesign/Sources/StarlingDesign/PairSymbol.swift` and `PairSymbolTests`
