# eedbi (Edit Encrypted Data Bag Item)

Create, edit, check, migrate and rekey [Chef encrypted data bag
items][encrypted data bag items] stored as JSON files, for example in a git
repository.

> A data bag item may be encrypted using [shared secret encryption][].
> This allows each data bag item to store confidential information (such
> as a database password) or to be managed in a source control system
> (without plain-text data appearing in revision history).

* **Small diffs.** Only the values you change get new ciphertext, so a
  pull request shows which secrets changed. `knife data bag edit`
  re-encrypts every value.
* **No Chef needed.** Only Ruby 3.1 or newer, which includes the Ruby
  embedded in Chef and Cinc 18 and later. The encryption formats are
  implemented with Ruby's standard OpenSSL library and tested against
  Chef's own implementation.
* **Any path.** Items do not need to be in a Chef repository layout, and no
  Chef server or local mode is involved.
* **Careful with plaintext.** It is edited in a private temporary directory,
  never left behind, and vim and neovim are kept from copying it elsewhere.

## Install

`eedbi` is not published as a gem yet. Run it from a checkout:

```bash
git clone https://github.com/jrwesolo/eedbi.git
export PATH="$PWD/eedbi/bin:$PATH"
```

Or build and install the gem locally with `gem build eedbi.gemspec` and
`gem install eedbi-*.gem`.

## Usage

```
Usage: eedbi COMMAND [options] ITEM [ARGS...]

Commands:
  edit        Edit an item in your editor, creating it if needed
  read        Print a decrypted item, or one value
  list        List the keys of an item
  write       Write a whole item from plaintext JSON
  import      Write a whole item from encrypted JSON
  set         Set one value of an item
  unset       Remove values from an item
  rename      Rename a key of an item
  migrate     Convert items to another encryption version
  check       Verify items: decryption, versions, and ids
  rekey       Re-encrypt items with a new secret
  new-secret  Create a new secret file
```

`eedbi help COMMAND` lists the options of a command, with examples. Every
command but `list`, `rename`, `unset`, `import` and `new-secret` accepts
the options described in [Secret](#secret), and all but `list`,
`rename`, `unset`, `migrate` and `new-secret` accept
`--decrypt-minimum-version` (see [Encryption
versions](#encryption-versions)). `list`, `rename`, `unset` and `import`
decrypt nothing, so they reject `-s` as a usage error; a script
that runs several commands with one secret should set
`$ENCRYPTED_DATA_BAG_SECRET` once instead of passing `-s` to each.

`edit`, `read`, `list`, `write`, `import`, `set`, `unset` and `rename` work
on the contents of one item. `migrate`, `check` and `rekey` apply to many
items at once, so that one call writes all of them or none, asks for a
secret once, and gives one result for CI.

stdin carries data, never the secret: the plaintext item for `write`, the
encrypted item for `import`, the value for `set`, and, when ITEM is `-`,
the item for `read`, `list` and `check`. `-` stands for a file to read;
`write`, `import` and `set` read stdin without it, since ITEM is the file
they write, or read `--from-file PATH` instead.

A KEY that starts with `-` would be read as an option, so put it after
`--`, which ends the options, and put any options before that:
`eedbi set mysql.json --dry-run -- -legacy`.

### edit

```bash
eedbi edit data_bags/db/mysql.json
eedbi edit mysql.json --editor 'code --wait'
eedbi edit tls.json certificate             # edit one value
eedbi edit mysql.json replicas --json-value # open the value as JSON, not plain text
eedbi edit mysql.json --encrypt-version 3   # changed values in version 3
```

Decrypts the item into your editor and encrypts the result when you close
it. A new item starts from a template with its `id` set to the file name.
Closing the editor without changes writes nothing, not even a new item.
If the file changes on disk while the editor is open, for example after a
`git pull`, `eedbi` asks before overwriting it; answering N, or pressing
Enter, discards your changes. Exiting the editor with an error (`:cq` in
vim) also discards them.

With a KEY, only that value opens in the editor. A string opens as plain
text with real line breaks instead of `\n` escapes, which is far easier for
certificates and private keys; whether it ends with a newline is kept as it
was. Other values open as JSON, and `--json-value` opens a string, or a new
key, as JSON too.

### read

```bash
$ eedbi read mysql.json
{
  "id": "mysql",
  "password": "abc123"
}
$ eedbi read mysql.json password
abc123
$ eedbi read mysql.json password --digest
hmac:3f9a1c0b7d2e4a68
$ git show main:data_bags/db/mysql.json | eedbi read -
```

With a KEY, `read` prints only that value: a string followed by one
newline, and anything else as JSON. The newline is always added, even to a
string that ends with one, as `jq -r` does, and `set` removes exactly one,
so `eedbi read a.json k | eedbi set b.json k` copies a value exactly.
`read` takes one item and one key at most, so its output is always one
document or one value. `-` reads the item from stdin, for example an older
version from git.

`--digest` prints a digest of each value instead of the value: an HMAC
with a key derived from the secret. Equal values give equal digests under
one secret, whatever their key, item or encryption version, while a
different value, or a `"5"` instead of a `5`, gives another. Without the
secret a digest can be neither reversed nor guessed, even for a short
password, unlike a plain hash such as `sha256sum` output. It answers "did
this value change?" or "are these two equal?" without showing either; see
[Git diffs](#git-diffs) and [Scripts and AI agents](#scripts-and-ai-agents).

### list

```bash
$ eedbi list legacy.json     # no secret needed
password
port
$ eedbi list legacy.json --versions
password  1
port      3
$ eedbi list legacy.json --format json
[
  "password",
  "port"
]
```

Lists the keys of an item, one per line, ready to pass to `read`, `edit`,
`set` or `unset`. The `id` is left out, since it is not encrypted. Nothing
is decrypted, so no secret is needed. `--versions` adds the encryption
version of each value (`unencrypted` for a plain value), for example to
find old values before raising the decrypt minimum; with `--format json`
it prints an object of keys and versions, with `null` for plain values.
To find old versions across many items, use `check --no-decrypt
--decrypt-minimum-version N`, which needs no secret either.

### write

```bash
$ cat plaintext.json
{
  "id": "mysql",
  "password": "abc123"
}
$ eedbi write mysql.json < plaintext.json
mysql.json: created the item with "password"
$ cat mysql.json
{
  "id": "mysql",
  "password": {
    "encrypted_data": "M6zquNyfXE7Etzcn5XAN5B+YVypVhlvqyg==\n",
    "iv": "fkFpEX/FE7Jg6ivB\n",
    "auth_tag": "3tizrkXBHxrm5NMM7wyacQ==\n",
    "version": 3,
    "cipher": "aes-256-gcm"
  }
}
```

Replaces the item's content with the JSON from stdin, or from
`--from-file PATH`, so keys missing from it are removed; `set` and `unset`
change single values. As with `edit`, values that did not change keep
their ciphertext. `--dry-run` names the keys that would be added, changed
or removed:

```bash
$ eedbi write mysql.json --dry-run < partial.json
mysql.json: would remove "port", "user"
```

Every command that writes names the item and the keys it changed, never
their values, for example `mysql.json: changed "password"` or
`tls.json: added "cert", removed "old_cert"`.

New items need a file name ending in `.json`, since knife only picks up
`data_bags/BAG/ITEM.json`. Existing files are read whatever their name.

Every command that writes puts the `id` first. Chef does not care about
key order, but a fixed place keeps files consistent. An `id` elsewhere is
not a change on its own; it moves the next time the item really changes.

The id comes from the file name, as `knife upload` requires: a missing id
is filled in, and a different one replaced. When the JSON had another id,
as when an item is copied from another, a note says so, since it may mean
the wrong file:

```bash
$ eedbi read staging.json | eedbi write prod.json
Note: id 'staging' from the input replaced with 'prod', from the file name
prod.json: changed "password"
```

A change to the id itself is reported with its values, since the id is
not encrypted: `old.json: changed id 'olde' to 'old'`. Files not named
`*.json` keep the id they are given.

`write` takes plaintext. Given an encrypted item, as from `git show`, it
would encrypt every value a second time, so it refuses when every changed
value already looks encrypted. To copy an encrypted item, use `import`;
to write such values on purpose, pass `--force`.

### import

```bash
$ knife data bag show db mysql -F json | eedbi import mysql.json
mysql.json: changed "password"
$ eedbi check mysql.json
ok    mysql.json (version 3)
```

Writes an encrypted item from stdin, or from `--from-file PATH`, to ITEM
as it is. Nothing is decrypted or encrypted, so no secret is needed. Use
it to bring in an item from the Chef server, another branch or another
repository. Every value must be encrypted, in a version no older than the
decrypt minimum, and plaintext is refused with a pointer to `write`.
Version 0 values are refused too, since plaintext can pass for them;
convert such items with `migrate` first. If knife has a secret
configured, `knife data bag show` prints plaintext, which `import`
therefore refuses.

ITEM is replaced even when it is not a valid item, such as after a merge
conflict. As with `write`, a file name ending in `.json` gives the id.
Since nothing is decrypted, run `eedbi check ITEM` afterwards to confirm
the secret reads it. `--dry-run` says what would change.

To restore an old copy from the same repository, git alone does it:
`git restore --source=main -- mysql.json`.

### set and unset

```bash
printf %s "$NEW_PASSWORD" | eedbi set mysql.json password
eedbi set mysql.json password                          # typed twice, without echo
echo 5432 | eedbi set mysql.json port --json-value     # a number, not a string
eedbi set tls.json certificate --from-file cert.pem    # byte for byte
eedbi unset mysql.json old_password legacy_token
```

Changes single values without an editor and without the rest of the item
passing through a pipe. Where the value comes from:

| Input | Value |
|---|---|
| stdin piped or redirected | the text, minus one trailing newline |
| stdin is a terminal | typed, twice and without echo, taken exactly as typed |
| `--from-file PATH` | the file's bytes, exactly, including any trailing newline |
| `--from-file -` | stdin's bytes, exactly |

The value is a string; `--json-value` parses it as JSON instead. On
Windows, prefer `--from-file`: PowerShell has no `<`, and Windows
PowerShell 5.1 pipes text to programs as ASCII by default, which turns
characters such as `ü` into `?`.

An empty value from stdin or a file is refused unless `--allow-empty` is
given, since it is far more often an unset variable or a script without
stdin than a value meant to be empty:

```bash
$ printf %s "$UNSET" | eedbi set mysql.json password
mysql.json: the value for "password" from stdin is empty. To set an empty string, pass --allow-empty.
```

`set` creates the item if it does not exist. `unset` writes nothing if any
key is missing, unless `--ignore-missing` is given, which skips missing
keys, for scripts that may run more than once. `unset` decrypts nothing,
so it needs no secret, and it can repair an item with a value committed
unencrypted, which the commands that decrypt refuse: unset the value,
then set it again. With `--dry-run`, both say which keys would change,
without writing anything or printing any value:

```bash
$ printf %s "$NEW_PASSWORD" | eedbi set mysql.json password --dry-run
mysql.json: would change "password"
```

### rename

```bash
eedbi rename mysql.json password db_password
```

Renames a key in place. The value keeps its ciphertext, since no
encryption version ties it to the key name, so no secret is needed. The
diff shows only the rename, so a reviewer without the secret can see the
value did not change, which editing the key name in `edit` cannot show.

### check

```bash
$ eedbi check data_bags/*/*.json --decrypt-minimum-version 2
FAIL  data_bags/app/old.json: uses encryption versions 0, 1 (minimum 2)
FAIL  data_bags/db/legacy.json: uses encryption version 1 (minimum 2)
ok    data_bags/db/mysql.json (version 3)
2 of 3 items failed
```

Verifies that each item is valid, decrypts with the secret, and, for a
file named `*.json`, has an `id` that matches the file name (`knife
upload` rejects items that do not, and ignores other files), without
printing any plaintext. Exits with 1 if any item fails.
Useful in CI; `--quiet` prints only the failures, and `-` checks an item
read from stdin. `--format json` prints the results as one JSON document,
with `--quiet` listing only the failed items:

```json
{
  "items": [
    { "path": "data_bags/db/legacy.json", "ok": false, "error": "uses encryption version 1 (minimum 2)" },
    { "path": "data_bags/db/mysql.json", "ok": true, "versions": [3] }
  ],
  "checked": 2,
  "failed": 1
}
```

A file that starts with a UTF-8 byte order mark, as some Windows editors
write, fails, since knife cannot parse it. Save it as UTF-8 without one
(in Notepad, the encoding "UTF-8" rather than "UTF-8 with BOM"; in VS
Code, "Save with Encoding"), or run the `perl` command the failure
shows.

An item with version 0 values passes, with a warning on stderr, and in
`warnings` with `--format json`: `knife data bag show` and chef-client's
`data_bag_item` return such an item without decrypting it (see
[Differences from knife](#differences-from-knife)). `eedbi migrate`
converts it.

`--no-decrypt` checks everything but decryption, and needs no secret:
every value must be encrypted, in version 1 or later, and in at least
the decrypt minimum version. Version 0 fails because plaintext can pass
for it: a version 0 value is a bare base64 string, and so is a password
from `openssl rand -base64 32`. It catches plaintext committed by
mistake where the secret is not available, such as CI for pull requests
from forks, or a pre-commit hook:

```bash
$ eedbi check data_bags/db/*.json --no-decrypt
ok    data_bags/db/mysql.json (version 3)
FAIL  data_bags/db/new.json: not encrypted: "password", "port"
1 of 2 items failed
```

### migrate

```bash
$ eedbi migrate data_bags/*/*.json
data_bags/app/old.json: converted version 0, 1, 2, 3 -> 3
data_bags/db/legacy.json: converted version 1 -> 3
data_bags/db/mysql.json: already version 3
```

Converts items to `--encrypt-version`, by default
`$EEDBI_DEFAULT_ENCRYPT_VERSION`, else 3, with the same secret and without
changing the plaintext. Values already in that version keep their
ciphertext. Lowering a version weakens the encryption, so it fails unless
`--allow-downgrade` is given:

```bash
$ eedbi migrate data_bags/db/mysql.json --encrypt-version 1
data_bags/db/mysql.json: would lower every value from version 3 to 1. Pass --allow-downgrade to lower versions.
Nothing was written (1 of 1 items failed)
```

`migrate` reads values below the decrypt minimum version, since upgrading
them is its job.

### rekey

```bash
eedbi new-secret new_secret
eedbi rekey data_bags/*/*.json --new-secret-file new_secret
eedbi rekey data_bags/*/*.json --new-secret-prompt
```

Decrypts each item with the current secret and encrypts every value with
the new one, each in the encryption version it is in now: `rekey`
changes the secret and nothing else. Version 0 cannot be written, so
items that use it fail with a pointer to `eedbi migrate`. Items that
already decrypt with the new secret are left as they are
(`mysql.json: already uses the new secret`), so running `rekey` again
after an interrupted run finishes the job.

Rotating the secret:

1. Create a new secret: `eedbi new-secret new_secret`.
2. `eedbi migrate` the items if any still use version 0, then
   `eedbi rekey` them with `--new-secret-file`.
3. Deploy the new secret everywhere the items are read: nodes, CI and
   workstations.
4. Retire the old secret.

`migrate` and `rekey` decrypt and re-encrypt every item in memory before
writing any of them, so a wrong secret or one broken item never leaves a
set of items half converted. Writing them is not one atomic step,
though: each file is replaced atomically, and a line is printed as each
is written. A write that fails, for example because someone else changed
the file meanwhile, is reported and the other items are still written.
Both commands skip items that are already done, so running the same
command again finishes a partial run, whether it failed or was
interrupted:

```bash
$ eedbi migrate data_bags/db/*.json
data_bags/db/legacy.json: converted version 1 -> 3
data_bags/db/mysql.json changed on disk while eedbi was running; not written
data_bags/db/redis.json: already version 3
1 of 3 items was not written. Run the same command again to finish.
```

`migrate`, `rekey`, `write`, `import`, `set`, `unset` and `rename` accept
`--dry-run` to show what would change without writing anything.

## Secret

The secret comes from, in order:

1. `--secret-file PATH` (`-s`)
2. `--secret-prompt`, which reads it from the terminal without echo, even
   when stdin is piped (`eedbi write ITEM --secret-prompt < plain.json`)
3. `$ENCRYPTED_DATA_BAG_SECRET`. When set, it must name an existing file;
   `eedbi` does not fall back to the locations below, which might hold a
   different secret.
4. `./encrypted_data_bag_secret`, `~/.chef/encrypted_data_bag_secret`,
   then `/etc/chef/encrypted_data_bag_secret` (`C:/chef/...` on Windows)

There is no option to pass the secret itself on the command line, where
it would be visible in `ps` output and shell history. stdin carries only
items and values, never the secret. To use a secret that is not in a
file, such as one from a password manager or a CI variable, give a
process substitution as the path (bash and zsh):

```bash
eedbi read mysql.json --secret-file <(pass show chef/data_bag_secret)
eedbi check data_bags/*/*.json --secret-file <(printf %s "$DATA_BAG_SECRET")
```

GitLab's file type CI variables already hold a path, which works directly
as `--secret-file` or `$ENCRYPTED_DATA_BAG_SECRET`. In a POSIX shell
without process substitution, such as `sh` or `dash` in many CI images,
give `/dev/stdin` as the path, as long as nothing else comes from stdin
in the same call (an item for `write` or `read -`, or a value for `set`):

```bash
printf %s "$DATA_BAG_SECRET" | eedbi check data_bags/*/*.json --secret-file /dev/stdin
```

On Windows, where neither works, write the secret to a file only you can
read, or use `--secret-prompt`.

Each item has one secret: Chef decrypts a whole item with the secret it
is loaded with, and knife, `eedbi read`, `check`, `migrate`, `rekey` and
git diffs all expect every value of an item to use it. To give different
people or nodes different secrets, put the values in separate items or
data bags, each with its own secret (see [Recipes](#recipes) for checking
them), or use [chef-vault](https://github.com/chef/chef-vault) for
access per node or per person.

The secret file is read exactly as knife and chef-client read it: as
UTF-8 text, whatever the locale, with leading and trailing whitespace
removed. A file that is not valid UTF-8, which Chef cannot load, is
refused. Chef reads it in text mode, so on Windows a CRLF line break
inside the secret becomes LF, and the same file gives a different key
there than elsewhere; `eedbi` warns about such a file, as it does when
the file is readable by every user on the system.

Create a new secret with:

```bash
eedbi new-secret ~/.chef/encrypted_data_bag_secret
```

It writes 512 random bytes, base64 encoded on one line, as Chef's
documentation does with `openssl rand -base64 512 | tr -d '\r\n'`, to a
file created with mode 0600. It never overwrites an existing file, since
the items encrypted with that secret could no longer be read, and never
prints the secret.

## Encryption versions

Chef supports several [encryption versions][]:

Version | Chef    | Cipher      | Integrity            | eedbi
------- | ------- | ----------- | -------------------- | ------------------
0       | 0.10+   | AES-256-CBC | none                 | decrypt only
1       | 11.0+   | AES-256-CBC | none                 | encrypt, decrypt
2       | 11.6+   | AES-256-CBC | HMAC-SHA256          | encrypt, decrypt
3       | 12.0+   | AES-256-GCM | GCM tag              | encrypt, decrypt

Only `eedbi migrate` converts whole items. `edit`, `set` and `write`
encrypt again only the values that change:

Value | Written in
----- | ----------
Unchanged | Keeps its ciphertext, whatever its version
Changed | Its own version
New key, or changed version 0 value (version 0 cannot be written) | The item's highest version, which everything that reads the item can already read
In a new item, or one with only version 0 values | `$EEDBI_DEFAULT_ENCRYPT_VERSION`, else 3

`--encrypt-version N` on `edit`, `set` and `write` writes the changed and
new values in N instead, and leaves the rest alone. It never lowers a
value's version; that takes `eedbi migrate --encrypt-version N
--allow-downgrade`, which converts the whole item. An item can therefore
hold values in several versions, which Chef reads fine; `eedbi list
--versions` lists them, and `eedbi migrate` evens them out.

Set `$EEDBI_DEFAULT_ENCRYPT_VERSION`, for example to `2` when old Chef
clients must read the items. It is also the default target of `migrate`.

`--decrypt-minimum-version N`, or `$EEDBI_DECRYPT_MINIMUM_VERSION`, refuses
values below version N, like Chef's `data_bag_decrypt_minimum_version`.
Versions 0 and 1 have no integrity protection, so once every item is
upgraded, a minimum of 2 keeps a value from being swapped back to one of
them unnoticed.

The names follow Chef's settings: `--encrypt-version` and
`$EEDBI_DEFAULT_ENCRYPT_VERSION` correspond to `data_bag_encrypt_version`
(which knife sets with `--config-option data_bag_encrypt_version=N`), and
`--decrypt-minimum-version` to `data_bag_decrypt_minimum_version`.

## Editor

The editor is chosen like git does: `--editor`, then `$EEDBI_EDITOR`,
`$VISUAL`, `$EDITOR`, and finally `vim` (or `vi`) on Unix and `notepad`
on Windows. The value may contain arguments, for example
`--editor 'code --wait'`. GUI editors must be told to wait until the file
is closed; otherwise `eedbi` sees no changes and says so.

An external editor needs a real file, so the decrypted item cannot be kept
purely in memory while editing. To limit exposure, `eedbi`:

* writes it to a private (0700) temporary directory, on a RAM backed
  filesystem when one is available (`$XDG_RUNTIME_DIR` or `/dev/shm`),
* removes that directory, including any swap or backup files the editor
  left next to the file, when editing ends, on Ctrl-C, or on SIGTERM,
* starts vim and neovim without swap, viminfo, backup, or undo files,
  since those can be configured to live outside the temporary directory,
  and keeps gvim and MacVim in the foreground (`-f`),
* checks that the item's directory exists and is writable before opening
  the editor, so edits cannot be lost to a failed save.

Other editors may keep their own copies. For example, VS Code's Local
History can save copies of files you save; exclude the temporary files
with the setting `"workbench.localHistory.exclude": {"**/eedbi*/**": true}`.

No command but `edit` writes plaintext to disk.

## Comments

Chef accepts `//` and `/* */` comments in data bag item files, outside the
encrypted values. Like knife, `eedbi` reads items that contain them but
does not keep them when it writes an item, including comments in the JSON
you type in the editor or pipe in. The removed lines show in `git diff`.

## Git diffs

Git can show decrypted items in `git diff`, `git log -p` and `git show`:

```bash
# .gitattributes, committed
data_bags/**/*.json diff=eedbi

# once per clone
git config diff.eedbi.textconv "eedbi read"
```

```diff
-  "password": "hunter2",
+  "password": "changed",
```

The secret is found as usual, so this works from the repository root when
`./encrypted_data_bag_secret` or `$ENCRYPTED_DATA_BAG_SECRET` is set.
Plaintext only appears in your terminal.

Give the attribute only to encrypted items, for example
`data_bags/secrets/*.json diff=eedbi`. `eedbi read` fails on an item that
is not encrypted, and git then stops the whole diff with "fatal: unable
to read files to diff", not just that file.

To see which values changed without seeing them, for example while
screen sharing, in CI logs, or for an AI agent, use digests instead:

```bash
git config diff.eedbi.textconv "eedbi read --digest"
```

```diff
-  "password": "hmac:3f9a1c0b7d2e4a68",
+  "password": "hmac:b41e77d09c5a2f13",
```

A pull request from `eedbi migrate` then shows no changed lines at all,
which proves no value changed even though every ciphertext did. (After
`eedbi rekey`, each side of the diff needs a different secret, so the
diff cannot be shown; `rekey` checks every item itself before writing.)

## Recipes

Change one field of a value that holds an object, without an editor:

```bash
eedbi read aws.json credentials \
  | jq '.region = "us-west-2"' \
  | eedbi set aws.json credentials --json-value
```

Change a whole item with jq. `read` finishes reading before `write`
writes, so reading and writing the same file in one pipeline is safe:

```bash
eedbi read mysql.json | jq '.port = 5433 | del(.legacy)' | eedbi write mysql.json
```

Check only the items a branch changed, in CI (`origin/main...HEAD`
compares with where the branch started, so changes made on main since
then are left out, `--diff-filter=d` leaves out deleted files, and
`xargs -r` runs nothing when there are none):

```bash
git diff --name-only --diff-filter=d origin/main...HEAD -- 'data_bags/*.json' \
  | xargs -r eedbi check --decrypt-minimum-version 2
```

Data bags with a secret each, where one `check` over all of them would
fail:

```bash
for bag in data_bags/*/; do
  name=$(basename "$bag")
  eedbi check "$bag"*.json --quiet --secret-file "secrets/$name" || failed=1
done
exit "${failed:-0}"
```

A pre-commit hook that refuses plaintext, with or without the secret
(`.git/hooks/pre-commit`, executable):

```bash
#!/bin/sh
git diff --cached --name-only --diff-filter=d -- 'data_bags/*.json' \
  | xargs -r eedbi check --quiet --no-decrypt
```

It checks the files as they are in the working tree, which is what gets
committed unless a file changed after `git add`, or was only partly
staged with `git add -p`.

## Scripts and AI agents

Everything but `edit` works without a terminal, nothing waits for input
that is not coming, and the exit status tells success (0), failure (1)
and a usage error (2) apart. Most work needs no plaintext on screen, in
logs, or in an AI agent's context, where it is sent to the model's
provider and kept in transcripts:

* `list`, `rename`, `unset`, `import`, `new-secret` and `check
  --no-decrypt` need no secret at all.
* `check`, `migrate` and `rekey` decrypt, but print only key names,
  paths and versions.
* `set` and `write` print only key names. Pipe values in from where they
  live, so they never appear on screen or in the command itself:

  ```bash
  vault kv get -field=password secret/db | eedbi set db.json password   # from a secret manager
  openssl rand -base64 32 | tr -d '\n' | eedbi set db.json password     # rotate to a random value
  eedbi read prod.json password | eedbi set staging.json password       # copy between items
  ```

* `read --digest` compares values without showing them: whether a value
  changed, whether two items hold the same password, or whether a `set`
  took effect.

Never put a value in the command line, such as `printf %s 'hunter2' |
eedbi set ...`: it ends up in shell history, in process listings, and in
an agent's context. Run writes with `--dry-run` first; it names the keys
that would change. `read` without `--digest`, and `edit`, are the only
commands that show plaintext.

Set `EEDBI_NO_PLAINTEXT` to any non-empty value in an agent's or CI job's
environment to make those two refuse, with a pointer to the commands
above. No option overrides it, so a command cannot opt out by mistake,
but it is a guard rail, not a security boundary: anything that can run
`eedbi` with the secret can also unset the variable. It refuses
`eedbi read prod.json password | eedbi set staging.json password` too,
since eedbi cannot tell a pipe into another command from a captured
output, and in `git diff` it needs the `--digest` textconv from
[Git diffs](#git-diffs). For Claude Code, for example, in
`.claude/settings.json`:

```json
{ "env": { "EEDBI_NO_PLAINTEXT": "1" } }
```

## Security notes

* Only values are encrypted. Key names and the `id` are plain text, so do
  not put secrets in them.
* Chef's format does not tie a ciphertext to its key, so someone who can
  write to the file can swap encrypted values between keys, or between
  items that share a secret, without detection. Review changes to items
  like any other code.
* Version 0 and 1 have no integrity protection at all. `eedbi check
  --decrypt-minimum-version 2` finds them, `eedbi migrate` upgrades them,
  and `$EEDBI_DECRYPT_MINIMUM_VERSION=2` refuses them from then on.
* Version 3 values with a truncated authentication tag are rejected.
  (Chef accepts them.)

## Differences from knife

eedbi reads items as Chef 19 does: the same formats, the same secret
file handling, the same values. `test/compat/fuzz_compat_test.rb` checks
it against Chef's own code on thousands of broken and unusual items:
eedbi never reads an item or value that Chef refuses, never reads a
different value, and what either one encrypts, the other decrypts.

Where they differ, eedbi refuses something Chef takes, because Chef
would hand a recipe ciphertext, `nil`, or a value it cannot print:

* **An item with any value that is not encrypted, including `null`.**
  `knife data bag show` and chef-client's `data_bag_item` then treat the
  whole item as unencrypted and return it as is, ciphertext and all;
  only `EncryptedDataBagItem.load` decrypts the rest, and returns `nil`
  for a `null`. eedbi reports the value as not encrypted.
* **Values that decrypt to what JSON cannot hold:** invalid UTF-8, a
  number too large for a float, `NaN`, or nesting deeper than 100
  levels. Chef returns them to Ruby, but knife cannot print or upload
  them either. Also a version 0 value holding a YAML symbol, which Chef
  returns as a Ruby symbol and knife prints as a string.
* **A decrypted value without Chef's `json_wrapper`**, which Chef reads
  as `nil`.
* **A version 3 authentication tag shorter than 16 bytes** (see
  [Security notes](#security-notes)).
* **In the item file:** a number too large for a float, invalid UTF-8,
  or nesting deeper than 100 levels, which knife parses but cannot
  upload; a lone UTF-16 surrogate such as `"\ud800"`, which knife
  silently turns into `?`; and an id with a line break, which Chef's id
  check lets through because it matches line by line.

One way eedbi takes more: an item file that starts with a UTF-8 byte
order mark, which some Windows editors add. knife cannot parse it.
eedbi reads it, so that it can still be edited, and leaves it out when
it writes the item, but `eedbi check` fails it.

One difference is Chef's own: `knife data bag show` and `data_bag_item`
decide that an item is encrypted only when every value looks like a
version 1 to 3 value. An item with any version 0 value is returned as
is, and only `EncryptedDataBagItem.load` decrypts it. eedbi reads it,
`eedbi check` warns about it, and `eedbi migrate` converts it so that
every part of Chef can.

## Windows

`eedbi` runs on Windows with any Ruby 3.1+ installation, including the
Ruby embedded in Chef Workstation. Quote editor paths that contain spaces
with double quotes, for example
`--editor '"C:\Program Files\Notepad++\notepad++.exe" -multiInst -nosession'`.

Terminals such as mintty (Git Bash) do not present a console to Ruby, so
`eedbi edit` reports that it needs a terminal there. Use
`winpty eedbi edit ...`, or run it from PowerShell or Windows Terminal.

## Exit status

`0` on success, including when there was nothing to change; `1` on errors,
discarded changes, and items that fail `check`; `2` on usage errors, such
as an unknown option or a missing argument, found before any file is read;
`130` when interrupted; `141`, silently, when the output goes to a pipe
that closed early, as with `| head -1`.

## Development

```bash
rake            # RuboCop and all tests
rake test:unit  # or test:cli, test:system, test:compat
```

Tests are in four layers: `test/unit` (single modules), `test/cli` (whole
commands in-process), `test/system` (`bin/eedbi` as a subprocess, under a
PTY, plus real vim and neovim), and `test/compat` (against Chef, skipped
without the `chef` or `cinc` gem). Only `test/compat` needs Chef, and only
`test/system` needs a PTY, so everything else runs on every platform,
Windows included.

`test/cli/fuzz_test.rb` gives every command malformed items and values,
and fails on any Ruby exception. Its cases are random but fixed by a
seed; `EEDBI_FUZZ_SEED=N EEDBI_FUZZ_CASES=1000 rake test:cli` tries
others.

The fixtures in `test/fixtures` are generated by Chef, for every
encryption version. See [test/fixtures/README.md](test/fixtures/README.md).

[encrypted data bag items]: https://docs.chef.io/client/latest/policy/data_bags/#encrypt-a-data-bag-item
[encryption versions]: https://docs.chef.io/client/latest/policy/data_bags/#encryption-versions
[shared secret encryption]: https://en.wikipedia.org/wiki/Symmetric-key_algorithm
