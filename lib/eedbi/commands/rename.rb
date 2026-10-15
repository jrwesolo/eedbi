# frozen_string_literal: true

module Eedbi
  module Commands
    # Renames a key without decrypting or re-encrypting its value.
    class Rename < Base
      command summary: 'Rename a key of an item',
              arguments: 'ITEM OLD NEW',
              description: <<~TEXT,
                Renames key OLD in ITEM to NEW, in the same place. The value
                keeps its ciphertext, which does not depend on the key name
                in any encryption version, so no secret is needed and the
                diff shows only the rename.
              TEXT
              examples: <<~TEXT
                eedbi rename data_bags/db/mysql.json password db_password
                eedbi rename data_bags/db/mysql.json password db_password --dry-run
              TEXT

      def execute((path, old, new))
        raise UsageError, 'The id cannot be renamed' if [old, new].include?('id')
        raise UsageError, 'OLD and NEW are the same key' if old == new

        loaded = read_existing(path)
        Store.check_writable!(path)
        raise Error, "#{path}: no key #{Eedbi.quote_key(old)}" unless loaded.item.key?(old)
        raise Error, "#{path}: key #{Eedbi.quote_key(new)} already exists" if loaded.item.key?(new)

        renamed = Item.id_first(loaded.item.to_h { |key, value| [key == old ? new : key, value] })
        Item.validate!(renamed)
        warn_id_mismatch(renamed, path)
        write_item(loaded, renamed) unless dry_run?
        verb = dry_run? ? 'would rename' : 'renamed'
        stdout.puts "#{path}: #{verb} #{Eedbi.quote_key(old)} to #{Eedbi.quote_key(new)}"
        0
      end

      private

      def check_arguments!(arguments)
        return if arguments.size == 3

        raise UsageError, "eedbi rename needs ITEM, OLD and NEW (#{received(arguments)})\n" \
                          "Run 'eedbi help rename' for usage."
      end

      def define_options(opts)
        define_dry_run_option(opts)
      end

      # No value is decrypted.
      def define_secret_options(opts); end
      def define_minimum_option(opts); end
    end
  end
end
