## edit_encrypted_data_bag_item

This script is used to aid in the editing of [encrypted data bag items](http://docs.opscode.com/chef/essentials_data_bags.html#encrypt-a-data-bag-item) used in in [Chef](http://docs.opscode.com/chef_overview.html). Encrypted data bag items are encrypted using [shared secret encryption](https://en.wikipedia.org/wiki/Symmetric-key_algorithm). In Chef, this is called your [_encrypted data bag secret_](http://docs.opscode.com/chef/essentials_data_bags.html#secret-keys).

### Usage

```
edit_encrypted_data_bag_item <data bag item> [options]
```

| Option | Description | Default |
| --------: | :---------- | :------ |
| `-s` `--secret` | location of encrypted data bag secret | `$ENCRYPTED_DATA_BAG_SECRET` or `$HOME/.chef/encrypted_data_bag_secret` |
| `-f` `--format` | [encrypted data bag version](http://docs.opscode.com/chef/essentials_data_bags.html#encryption-versions) | `2` |
| `-e` `--editor` | editor to use | `$EDITOR` or `vi` |
| `-h` `--help` | display the usage information | |

If the encrypted data bag item JSON file already exists, the script will decrypt the data and store it in a plaintext temporary file. If the encrypted data bag item JSON file does not exist, it will create a basic template for you to edit. Once your changes have been made, they will be encrypted and saved back to the original file. The plaintext temporary file will then be deleted.

### Dependencies

This script depends on the [chef](https://rubygems.org/gems/chef) gem for the encryption and decryption. Please make sure it is available.

### Preparation

You can generate your own encrypted data bag secret using the following command:

```bash
openssl rand -base64 512 | tr -d '\r\n' > encrypted_data_bag_secret
```

By default, the script will look in `$ENCRYPTED_DATA_BAG_SECRET` or `$HOME/.chef/encrypted_data_bag_secret`. This can be overridden in the options (see below).

#### Recovery on Parsing Error

In the event that there is a JSON parsing error, a copy of the edits (in plaintext) will be saved to the same directory as the data bag item (`example.json` saves as `.example.json.saved`). If a recovered file is detected, it will be restored when another editing attempt is made. Once restored, the recovered file is deleted. If another parsing error is encountered, the recovery process will occur again.

#### "Digest::Digest is deprecated; use Digest"

This message may be displayed when the data is decrypted and encrypted. This is due to code internal to the chef gem and therefore cannot be avoided. It is safe to ignore this error and it will eventually go away once the offending code is removed from future releases of the chef gem.