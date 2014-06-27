# edit_encrypted_data_bag_item

This script is used to aid in the editing of [encrypted data bag items](http://docs.opscode.com/chef/essentials_data_bags.html#encrypt-a-data-bag-item) used in in [Chef](http://docs.opscode.com/chef_overview.html). 

> A data bag item may be encrypted using [shared secret encryption](https://en.wikipedia.org/wiki/Symmetric-key_algorithm). This allows each data bag item to store confidential information (such as a database password) or to be managed in a source control system (without plain-text data appearing in revision history). Each data bag item may be encrypted individually; if a data bag contains multiple encrypted data bag items, these data bag items are not required to share the same encryption keys.

Ideally, encrypted data bag items will be stored in a version control system in their encrypted form. Editing an encrypted data bag item can be cumbersome to do by hand. Using this script automates the decryption, editing, and encryption process. Hopefully, by making the process easier, it will promote safer storage of sensitive data.

## Usage

```bash
edit_encrypted_data_bag_item <data bag item> [options]
```

### Options

| Short | Long | Description | Default |
| ----: | :--- | :---------- | :------ |
| -s | \-\-secret | location of encrypted data bag secret | `$ENCRYPTED_DATA_BAG_SECRET` or `$HOME/.chef/encrypted_data_bag_secret` |
| -f | \-\-format | [encrypted data bag version](http://docs.opscode.com/chef/essentials_data_bags.html#encryption-versions) | `2` (recommended, requires Chef >= 11.6) |
| -e | \-\-editor | editor to use | `$EDITOR` or `vi` |
| -h | \-\-help | display the usage information | |

If the encrypted data bag item JSON file already exists, the script will decrypt the data and store it in a plaintext temporary file. If the encrypted data bag item JSON file does not exist, it will create a basic template for you to edit. Once your changes have been made, they will be encrypted and saved back to the original file. The plaintext temporary file will then be deleted.

### Preparation

You can generate your own encrypted data bag secret using the following command:

```bash
openssl rand -base64 512 | tr -d '\r\n' > encrypted_data_bag_secret
```

### Dependencies

This script depends on the [chef](https://rubygems.org/gems/chef) gem for the encryption and decryption. Please make sure it is available.

By default, the script will look in `$ENCRYPTED_DATA_BAG_SECRET` or `$HOME/.chef/encrypted_data_bag_secret`. This can be overridden in the options (see above).

### Recovery on JSON Parsing Error

In the event that there is a JSON parsing error, a copy of the edits (in plaintext) will be saved to the same directory as the data bag item (`example.json` saves as `.example.json.saved`). If a recovered file is detected, it will be restored when another editing attempt is made. Once restored, the recovered file is deleted. If another parsing error is encountered, the recovery process will occur again.

### "Digest::Digest is deprecated; use Digest"

This message may be displayed when the data is decrypted and encrypted. This is due to code internal to the chef gem and therefore cannot be avoided. It is safe to ignore this error and it will eventually go away once the offending code is removed from future releases of the chef gem.

## Contributors

Jordan Wesolowski (<jrwesolo@gmail.com>)
