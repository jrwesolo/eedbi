# eedbi (Edit Encrypted Data Bag Item)

This script is used to assist in creating and editing [encrypted data
bag items][] used in [Chef][].

> A data bag item may be encrypted using [shared secret encryption][].
> This allows each data bag item to store confidential information (such
> as a database password) or to be managed in a source control system
> (without plain-text data appearing in revision history). Each data bag
> item may be encrypted individually; if a data bag contains multiple
> encrypted data bag items, these data bag items are not required to
> share the same encryption keys.

Ideally, encrypted data bag items will be stored in a version control
system in their encrypted form. Editing an encrypted data bag item can
be cumbersome to do by hand. Using this script automates the decryption,
editing, and encryption process without needing to resort to using a
Chef server or `knife` in local mode. Hopefully, by making the process
easier, it will promote safer storage of sensitive data.

## Usage

```
eedbi <data bag item> [options]
    -s, --secret-file PATH           Location of the encrypted data bag secret file
                                     Default locations (in order of precedence):
                                       $ENCRYPTED_DATA_BAG_SECRET
                                       ./encrypted_data_bag_secret
                                       ~/.chef/encrypted_data_bag_secret
                                       /etc/chef/encrypted_data_bag_secret
    -S, --secret SECRET              Secret to use for encryption
                                     It is preferred to use --secret-file to avoid
                                     leaking the secret or viewing it in plain text.
    -e, --editor EDITOR              Editor to use (default: $EDITOR or vi)
    -f, --force                      Re-encrypt all keys even if there are no changes
                                     (default: only re-encrypt changed keys)
    -b, --batch                      Do not prompt for file editing
        --show                       Print decrypted data bag item and exit
        --format VERSION             Encryption version (default: see notes below)
    -h, --help                       Show this message
```

If the encrypted data bag item JSON file already exists, the script will
decrypt the data and store it in a plaintext temporary file for the life
of the edit operation. If the encrypted data bag item JSON file does not
exist, it will create a basic template for you to edit. Once your
changes have been made, they will be encrypted and saved back to the
original file.

## Demo

The following code was executed in the `fixtures/` directory. The
encrypted data bag secret file in that directory is implicitly used by
`eedbi`.

```bash
$ eedbi new.json # editor will open for editing
Changes saved
$ cat new.json
{
  "id": "new",
  "username": {
    "encrypted_data": "JlSlLJ44a5XoPL3YoNfqTlIZ03T19oXf\n",
    "iv": "sGpp06Cjpobq8oeb\n",
    "auth_tag": "8U/jQo0LON/D7d/Y5kXz0w==\n",
    "version": 3,
    "cipher": "aes-256-gcm"
  },
  "password": {
    "encrypted_data": "/SzT8YOdzolPfAGKBaCRfW/22xg7y33LNQ==\n",
    "iv": "uRY6pEKfeVchx+qi\n",
    "auth_tag": "YjuJiloLHCSc6WiyHATjRA==\n",
    "version": 3,
    "cipher": "aes-256-gcm"
  }
}
$ eedbi new.json --show
{
  "id": "new",
  "username": "admin",
  "password": "abc123"
}
```

### Using STDIN

It is also possible to redirect output into `eedbi` instead of using an
editor. This could be useful to encrypt a plaintext JSON file. For
example:

```bash
$ cat plaintext.json
{
  "id": "mysql",
  "password": "abc123"
}
$ cat plaintext.json | eedbi new.json
Changes saved
$ cat new.json
{
  "id": "mysql",
  "password": {
    "encrypted_data": "beXT+crByeYa7La+Rka7zyQCbREM4eKnBg==\n",
    "iv": "c2DLAl1VE8uRKpzc\n",
    "auth_tag": "XawFrtlkxGtaoB0JjWgJvQ==\n",
    "version": 3,
    "cipher": "aes-256-gcm"
  }
}
$ eedbi new.json --show
{
  "id": "mysql",
  "password": "abc123"
}
```

## Secret File or Secret?

Only one of these options may be passed. It is recommended to have the
encrypted data bag secret in a file. Passing this file to `eedbi` will
then prevent leaking the secret into places such as the shell history.
If desired, the plain text secret can also be used.

```bash
# with --secret-file (recommended)
$ eedbi test.json --secret-file encrypted_data_bag_secret

# with --secret
$ eedbi test.json --secret 'Correct Horse Battery Staple'
```

## Format Version

Chef can use different [encryption versions] with a data bag item.
Depending on the Chef version available to `eedbi`, the best version
will used by default. The following table shows the current defaults
depending on Chef version:

Chef Version | Format
------------ | ------
` < 11.0`    | 0
` < 11.6`    | 1
` < 12.0`    | 2
`>= 12.0`    | 3

## Generate Your Own Secret

You can generate your own encrypted data bag secret using the following
command:

```bash
openssl rand -base64 512 | tr -d '\r\n' > encrypted_data_bag_secret
```

Any non-empty file will suffice, but this is the usual approach for
encrypted data bag secrets.

[Chef]: https://docs.chef.io/chef_overview.html
[encrypted data bag items]: https://docs.chef.io/data_bags.html#encrypt-a-data-bag-item
[encryption versions]: https://docs.chef.io/data_bags.html#encryption-versions
[shared secret encryption]: https://en.wikipedia.org/wiki/Symmetric-key_algorithm
