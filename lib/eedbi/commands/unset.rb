# frozen_string_literal: true

module Eedbi
  module Commands
    # Removes values from an item without decrypting anything.
    class Unset < Base
      command summary: 'Remove values from an item',
              arguments: 'ITEM KEY...',
              description: <<~TEXT,
                Removes each KEY from ITEM. Fails, writing nothing, if any KEY
                is missing, unless --ignore-missing is given, which skips
                missing keys, for scripts that may run more than once. Other
                values keep their ciphertext.

                Nothing is decrypted, so no secret is needed. That also
                repairs an item with a value committed unencrypted, which
                the commands that decrypt refuse: unset the value, then set
                it again.
              TEXT
              examples: <<~TEXT
                eedbi unset data_bags/db/mysql.json old_password
                eedbi unset data_bags/db/mysql.json old_password legacy_token --dry-run
                eedbi unset data_bags/db/mysql.json legacy_token --ignore-missing
              TEXT

      def execute((path, *keys))
        raise UsageError, 'The id cannot be removed from an item' if keys.include?('id')

        loaded = read_existing(path)
        Store.check_writable!(path)
        before = loaded.item
        missing = keys.reject { |key| before.key?(key) }
        unless missing.empty? || @options[:ignore_missing]
          raise Error, "#{path}: no #{missing.size == 1 ? 'key' : 'keys'} #{Eedbi.quote_keys(missing)}"
        end

        after = Item.id_first(before.except(*keys))
        Item.validate!(after)
        warn_id_mismatch(after, path)
        result = Changes.any?(before, after) ? :saved : :unchanged
        write_item(loaded, after) if result == :saved && !dry_run?
        report_save(loaded, result, before, after)
        0
      end

      private

      def check_arguments!(arguments)
        return if arguments.size >= 2

        raise UsageError, "eedbi unset needs ITEM and at least one KEY\nRun 'eedbi help unset' for usage."
      end

      def define_options(opts)
        opts.on('--ignore-missing', 'Skip keys the item does not have, instead of failing') do
          @options[:ignore_missing] = true
        end
        define_dry_run_option(opts)
      end

      # No value is decrypted.
      def define_secret_options(opts); end
      def define_minimum_option(opts); end
    end
  end
end
