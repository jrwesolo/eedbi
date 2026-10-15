# frozen_string_literal: true

module Eedbi
  module Commands
    # Writes a whole item from plaintext JSON.
    class Write < Base
      include ItemInput

      command summary: 'Write a whole item from plaintext JSON',
              arguments: 'ITEM',
              description: <<~TEXT,
                Reads the plaintext item as JSON from stdin, or from
                --from-file, and encrypts it into ITEM, replacing its content:
                keys missing from the JSON are removed. When ITEM already
                exists, values that did not change keep their ciphertext. To
                change single values, use 'eedbi set' or 'eedbi unset'.

                For a file name ending in .json, the id comes from the file
                name, as knife upload requires: a missing id is filled in,
                and a different one replaced, with a note. The JSON must be
                plaintext: when every changed value looks encrypted already,
                write refuses unless --force is given. To copy an encrypted
                item as is, use 'eedbi import'.

                Only the values that change are encrypted again, each in its
                own version unless --encrypt-version is given; 'eedbi migrate'
                converts whole items. Version 0 cannot be written, so changed
                version 0 values take the item's highest version.
              TEXT
              examples: <<~TEXT
                eedbi write data_bags/db/mysql.json < plain.json
                eedbi write data_bags/db/mysql.json --from-file plain.json --dry-run
                eedbi read data_bags/db/mysql.json | jq '.port = 5433' | eedbi write data_bags/db/mysql.json
              TEXT

      def execute((path))
        if reads_stdin? && @context.stdin_tty
          raise Error, 'eedbi write reads the item from stdin, but stdin is a terminal. Pipe it in ' \
                       '(eedbi write ITEM < plain.json) or use --from-file PATH; to edit interactively, ' \
                       "use 'eedbi edit ITEM'."
        end

        loaded = read_or_new(path)
        before_plain = decrypt(loaded)
        Store.check_writable!(path)

        input = read_item_input
        # Before the note about the id, which is moot if nothing is written.
        refuse_encrypted!(before_plain, input)
        after_plain = with_file_id(path, input, before_plain['id'])
        conflict = -> { raise Error, "#{path} changed on disk while eedbi was running. Nothing was written." }
        report_save(loaded, save(loaded, before_plain, after_plain, on_conflict: conflict), before_plain, after_plain)
        0
      end

      private

      def stdin_usage = 'eedbi write ITEM < plain.json'

      def define_options(opts)
        define_from_file_option(opts, 'Read the item JSON from PATH instead of stdin (- for stdin)')
        define_dry_run_option(opts)
        define_write_version_option(opts)
        opts.on('--force', 'Write even if every changed value looks encrypted already') do
          @options[:force] = true
        end
      end

      # An encrypted item piped in, as from git show, would be encrypted a
      # second time. 'eedbi import' copies it as is; --force writes it anyway.
      def refuse_encrypted!(before_plain, after_plain)
        changed = Changes.changed_keys(before_plain, after_plain)
        return if @options[:force] || !Item.looks_encrypted?(changed.map { |key| after_plain[key] })

        raise Error, 'every changed value looks encrypted already, and write takes plaintext. ' \
                     "To copy an encrypted item as is, use 'eedbi import'; to write it anyway, pass --force."
      end
    end
  end
end
