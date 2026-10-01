# Noise test vectors

Published test vectors for the two Noise protocols Starling uses, run by `NoiseVectorTests` (ADR 0003 care requirement 2). Each file keeps only the `Noise_XX_25519_ChaChaPoly_SHA256` and `Noise_KK_25519_ChaChaPoly_SHA256` entries from the upstream file. The entries themselves are unmodified: every key, prologue, payload, ciphertext, and handshake hash is copied as published.

| File | Upstream | Commit that last touched the upstream file | License |
|------|----------|---------------------------------------------|---------|
| `cacophony-xx-kk.json` | [cacophony](https://github.com/haskell-cryptography/cacophony), `vectors/cacophony.txt` ([raw](https://raw.githubusercontent.com/haskell-cryptography/cacophony/master/vectors/cacophony.txt)) | `18b7348c54fd61fcd0c220298883de0d09c8364d` (2018-12-16) | [Unlicense](https://github.com/haskell-cryptography/cacophony/blob/master/LICENSE) (public domain) |
| `snow-xx-kk.json` | [snow](https://github.com/mcginty/snow), `tests/vectors/snow.txt` ([raw](https://raw.githubusercontent.com/mcginty/snow/main/tests/vectors/snow.txt)) | `d00b360cc61a7fe519ce7539974dca4f36c4654a` (2025-03-04) | Apache-2.0 OR MIT ([LICENSE-APACHE](https://github.com/mcginty/snow/blob/main/LICENSE-APACHE), [LICENSE-MIT](https://github.com/mcginty/snow/blob/main/LICENSE-MIT)); used here under MIT |

Both licenses are compatible with this repository's Apache-2.0 license. Neither upstream vector file carries its own license header, so each upstream repository's license applies.

The snow MIT license requires its notice to be kept with copies:

```
MIT License

Copyright (c) 2021 Jake McGinty

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

To regenerate: download the upstream file and keep the vectors whose `protocol_name` is exactly one of the two names above.
