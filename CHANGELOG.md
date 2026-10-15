# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## 1.0.0 (unreleased)

A rewrite of the original single-file script, which needed the `chef` gem.
The command line is new and not compatible with the old script.

### Upgrading from the old script

| Old                                   | New                                         |
| ------------------------------------- | ------------------------------------------- |
| `eedbi ITEM`                          | `eedbi edit ITEM`                           |
| `eedbi ITEM < plain.json`             | `eedbi write ITEM < plain.json`             |
| `eedbi ITEM --show`                   | `eedbi read ITEM`                           |
| `eedbi ITEM --batch --format 3`       | `eedbi migrate ITEM... --encrypt-version 3` |
| `--format N`                          | `eedbi migrate --encrypt-version N` for whole items, `--encrypt-version N` on `edit`, `set` and `write` for changed values |
| `-f`, `--force`                       | Removed: re-encrypting with the same secret adds nothing; `eedbi rekey` changes the secret. `write --force` now writes input that already looks encrypted |
| `-S`, `--secret SECRET`               | `--secret-file PATH`, `--secret-file <(command)`, or `--secret-prompt` |

* Existing items keep their encryption version. The old script wrote every
  changed value in the version that matched the installed Chef, which
  could leave values in several versions without being asked to. Now
  `edit`, `set` and `write` encrypt again only the values that change,
  each in its own version, or in `--encrypt-version` when given. Only
  `migrate` converts whole items, and lowering a version needs
  `--allow-downgrade`.
* `edit` requires a terminal. The old script guessed from whether stdin
  was a terminal, and silently saved the item unchanged when stdout was
  redirected. stdin now carries only items (`write`, `import`, `read -`,
  `list -`, `check -`) and values (`set`), never the secret.
* New items need a file name ending in `.json`, which knife requires.
* Invalid `id` values are rejected, and `edit` requires an `id`; `write`
  and `import` take it from the file name.
* Repeated keys in edited or piped JSON are rejected.
* A set but missing `$ENCRYPTED_DATA_BAG_SECRET` is an error instead of
  falling back to another secret file.

### Added

* Commands `check` (for CI), `list`, `migrate`, `rekey`, `set`, `unset`,
  `rename`, `import`, `new-secret`, and `read ITEM KEY`. `edit`, `read`,
  `list`, `write`, `import`, `set`, `unset` and `rename` take one item;
  `migrate`, `check` and `rekey` take many, and `migrate` and `rekey`
  write nothing unless every item succeeds.
  `--dry-run` for `migrate`, `rekey`, `write`, `import`, `set`, `unset`
  and `rename`; for the last five it says what would change, without
  values.
* `read ITEM KEY` prints a string with one newline after it, always, so
  `read | set` copies a value exactly. `read --digest` prints an HMAC of
  each value, keyed by the secret, to compare values or review diffs
  without plaintext.
* Commands that write an item name the keys they changed, never values,
  instead of "Changes saved".
* `check --no-decrypt` checks without the secret that every value is
  encrypted, in version 1 or later, for CI without the secret and
  pre-commit hooks.
* Examples in `eedbi help COMMAND`; environment variables and exit
  status in `eedbi help`. "Did you mean" suggestions for mistyped
  commands and options.
* `edit ITEM KEY` edits one value; strings open as plain text with real
  line breaks, and `--json-value` opens a string or a new key as JSON.
* `set` reads the value from stdin, prompts for it twice without echo
  when stdin is a terminal, or reads `--from-file PATH` byte for byte;
  `write --from-file PATH` reads the item from a file. `set
  --json-value` parses the value as JSON. `set` refuses an empty value
  unless `--allow-empty` is given.
* `check` fails `*.json` items whose `id` does not match the file name,
  which `knife upload` rejects, and files that start with a byte order
  mark, which knife cannot parse. It warns about items with version 0
  values, which `knife data bag show` and chef-client's `data_bag_item`
  return without decrypting. `check --quiet` prints only failures.
* `rename` renames a key without the secret, keeping its ciphertext.
* `import` writes a whole item from encrypted JSON as is, needing no
  secret, for example from `knife data bag show BAG ITEM -F json`.
  `write` refuses an item whose changed values all look encrypted
  already, unless `--force` is given.
* `new-secret PATH` creates a secret file: 512 random bytes, base64
  encoded, as Chef recommends, with mode 0600. It never overwrites a file
  and never prints the secret.
* `write` and `import` take the id from the file name, as `knife upload`
  requires, with a note when the input had another id. Changes to the id
  are reported with its values.
* `list` lists the key names of an item, and with `--versions` the
  encryption version of each value, without the secret.
* `--format json` for `check` and `list`.
* `rekey` changes only the secret: every value keeps its encryption
  version, and items using version 0 need `migrate` first. Items that
  already decrypt with the new secret are skipped, so running it again
  after an interrupted run finishes the job.
* `migrate` and `rekey` print each item as it is written. A write that
  fails no longer stops the others, and running the command again
  finishes a partial run.
* `unset` needs no secret, so it can remove a value committed
  unencrypted. `unset --ignore-missing` skips missing keys instead of
  failing.
* `migrate` converts to `$EEDBI_DEFAULT_ENCRYPT_VERSION`, else 3, unless
  `--encrypt-version` is given.
* "Did you mean ITEM.json?" when a file is missing.
* `read -`, `list -` and `check -` read the item from stdin.
* The `id` is always written first.
* Items with `//` or `/* */` comments can be read, as Chef allows them.
  Like knife, eedbi does not keep them when it writes an item.
* `--secret-prompt`, which reads the secret without echo, even while
  stdin carries an item. `rekey` takes the new secret from
  `--new-secret-file` or `--new-secret-prompt`.
* `$EEDBI_DEFAULT_ENCRYPT_VERSION` for the version of new items, and
  `--decrypt-minimum-version` / `$EEDBI_DECRYPT_MINIMUM_VERSION` to refuse
  older versions, named after Chef's `data_bag_encrypt_version` and
  `data_bag_decrypt_minimum_version`.
* Encryption version 0 (Chef 0.10) can be read.
* Editor precedence like git: `--editor`, `$EEDBI_EDITOR`, `$VISUAL`,
  `$EDITOR`, then `vim`/`vi`, or `notepad` on Windows. Editor settings
  with arguments, such as `code --wait`, work.
* Windows support.
* A prompt before overwriting an item that changed on disk while the editor
  was open.
* Exit status 2 for usage errors, so scripts can tell them from failures,
  and 141, without a message, when the output goes to a pipe that closed
  early, as with `| head -1`.
* `--version`, a gemspec, and documentation for plaintext `git diff`.

### Changed

* Chef is no longer needed; only Ruby 3.1 or newer. Startup is about
  0.05s instead of about 0.8s.
* Plaintext is edited in a private 0700 directory, on a RAM backed
  filesystem when available, and removed on exit, Ctrl-C and SIGTERM.
  vim and neovim run without swap, viminfo/shada, backup and undo files.
* Items are written atomically, keep their file mode and symlinks, and
  always use LF line endings. A symlink to a missing file is refused
  rather than replaced.
* The default encryption version no longer depends on the installed Chef
  version (the old script read "11.10" as 11.1 and picked version 1).

### Fixed

* A new key with a `null` value was written unencrypted.
* A failing or missing editor reported "No changes found" and exit 0.
* End of input at the "Edit again" prompt crashed.
* `--show` on a missing file exited silently.
* A save into a missing or read-only directory lost the edit.

### Security

* Version 3 values with an authentication tag shorter than 16 bytes are
  rejected. OpenSSL accepts tags as short as one byte, which allowed
  forging a value in about 256 attempts without the secret.
* `eedbi` warns when the secret file is readable by every user, and when
  it has CRLF line breaks inside the secret, which Chef reads as LF on
  Windows only, giving a different key there.
