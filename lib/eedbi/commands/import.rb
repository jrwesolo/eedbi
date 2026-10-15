# frozen_string_literal: true

module Eedbi
  module Commands
    # Writes a whole item from encrypted JSON as it is, needing no secret.
    class Import < Base
      include ItemInput

      command summary: 'Write a whole item from encrypted JSON',
              arguments: 'ITEM',
              description: <<~TEXT,
                Reads an encrypted item as JSON from stdin, or from
                --from-file, and writes it to ITEM as it is: nothing is
                decrypted or encrypted, so no secret is needed. Use it to bring
                in an item from the Chef server, another branch or another
                repository. ITEM is replaced, even when it is not valid JSON,
                such as after a merge conflict. As with write, a file name
                ending in .json gives the id.

                Every value must be encrypted, in version 1 or later and no
                older than the decrypt minimum. Nothing is decrypted, so run
                'eedbi check ITEM' afterwards to confirm that the secret reads
                it. To encrypt plaintext, use 'eedbi write'.
              TEXT
              examples: <<~TEXT
                knife data bag show db mysql -F json | eedbi import data_bags/db/mysql.json
                git show main:data_bags/db/mysql.json | eedbi import data_bags/db/mysql.json
                eedbi import data_bags/db/mysql.json --from-file backup/mysql.json --dry-run
              TEXT

      def execute((path))
        if reads_stdin? && @context.stdin_tty
          raise Error, 'eedbi import reads the item from stdin, but stdin is a terminal. Pipe it in ' \
                       '(knife data bag show BAG ITEM -F json | eedbi import ITEM) or use --from-file PATH.'
        end

        loaded = current(path)
        Store.check_writable!(path)
        input = read_item_input
        # Before the note about the id, which is moot if nothing is written.
        check_encrypted!(input)
        item = with_file_id(path, input, loaded.item['id'])
        Item.validate!(item)

        result = Changes.any?(loaded.item, item) ? :saved : :unchanged
        write_item(loaded, item) if result == :saved && !dry_run?
        if @invalid
          stdout.puts "#{path}: #{dry_run? ? 'would replace' : 'replaced'} the invalid item"
        else
          report_save(loaded, result, loaded.item, item)
        end
        0
      end

      private

      def stdin_usage = 'eedbi import ITEM < item.json'

      def define_options(opts)
        define_from_file_option(opts, 'Read the item JSON from PATH instead of stdin (- for stdin)')
        define_dry_run_option(opts)
      end

      # Nothing is decrypted.
      def define_secret_options(opts); end

      # The item to replace. One that is not a valid item, such as one with
      # merge conflict markers, is replaced all the same.
      def current(path)
        read_or_new(path)
      rescue Error
        raise unless ::File.file?(path)

        @invalid = true
        Store::Loaded.new(path, {}, ::File.binread(path))
      end

      # Every value encrypted, in a valid and not too old version. Version 0
      # is refused: it is a bare base64 string, which plaintext can pass
      # for, and it dates from Chef 0.10.
      def check_encrypted!(item)
        values = item.except('id')
        plain = Item.unencrypted_keys(item)
        raise Error, "not encrypted: #{Eedbi.quote_keys(plain)}. To encrypt plaintext, use 'eedbi write'." if plain.any?

        Item.check_fields!(item)
        old = Item.version_0_keys(item)
        unless old.empty?
          raise Error, "uses encryption version 0 (#{Eedbi.quote_keys(old)}), which plaintext can pass for. " \
                       "Convert the item with 'eedbi migrate' first, or use 'eedbi write' for plaintext."
        end

        versions = values.values.map { |field| Crypto.version_of(field) }.uniq.sort
        below = versions.select { |version| version < decrypt_minimum }
        raise Error, "uses encryption version #{below.join(', ')} (minimum #{decrypt_minimum})" unless below.empty?
      end
    end
  end
end
