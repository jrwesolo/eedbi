# Test fixtures

Test secrets and data bag items. None of the secrets protect anything real.

File                        | Contents
--------------------------- | ---------------------------------------------------------------
`encrypted_data_bag_secret` | Secret for every encrypted fixture except `wrong_key.json`
`other_secret`              | A second secret, for wrong-key tests and `wrong_key.json`
`plain.json`                | The plaintext: strings, numbers, booleans, null, arrays, nested objects, non-ASCII text
`v0.json`                   | `plain.json` in encryption version 0 (Chef 0.10, decrypt only)
`v1.json`                   | `plain.json` in encryption version 1
`v2.json`                   | `plain.json` in encryption version 2
`v3.json`                   | `plain.json` in encryption version 3
`mixed.json`                | `plain.json` with values in versions 0, 1, 2 and 3
`wrong_key.json`            | `plain.json` in version 3, encrypted with `other_secret`

Every encrypted item has the same values as `plain.json`, and its file name as
its `id`.

## Regenerating

The encrypted items are written by Chef's own implementation, not by eedbi, so
that the tests compare the two. `plain.json` and the secrets are the inputs
and are edited by hand.

```bash
ruby test/fixtures/generate.rb          # needs the chef or cinc gem
ruby test/fixtures/generate.rb --check  # fails if any fixture is stale
```

IVs are derived from the item and key names, so regenerating gives identical
files and every value is also a known-answer test vector: eedbi, given the
same IV, must produce exactly Chef's bytes
(`test/unit/fixtures_test.rb`). Never fix IVs outside of test fixtures.
Reusing an IV with the same secret breaks the encryption.

Tests copy these files into a temporary directory and never modify them.
