# frozen_string_literal: true

module Eedbi
  module Commands
    # Verifies that items decrypt, for example in CI.
    class Check < Base
      command summary: 'Verify items: decryption, versions, and ids',
              arguments: 'ITEM...',
              description: <<~TEXT,
                Checks that each ITEM is a valid item that decrypts with the
                secret, and with a decrypt minimum version that no value uses
                an older encryption version. Prints one line per item and exits
                with 1 if any item fails; --quiet prints only failures. For a
                file named *.json, the id must match the file name, as knife
                upload requires. ITEM can be - to read the item from stdin.
                Plaintext is never printed. --format json prints the results
                as one JSON document. A file that starts with a UTF-8 byte
                order mark fails, since knife cannot parse it. Items with
                version 0 values pass with a warning: knife data bag show and
                chef-client's data_bag_item do not decrypt them.

                --no-decrypt checks everything but decryption, without a
                secret: every value must be encrypted, in version 1 or later,
                since plaintext can pass for version 0. This catches
                plaintext committed by mistake where the secret is not
                available, such as pull requests from forks or pre-commit
                hooks.
              TEXT
              examples: <<~TEXT
                eedbi check data_bags/db/*.json
                eedbi check data_bags/*/*.json --quiet --decrypt-minimum-version 2
                eedbi check data_bags/db/*.json --no-decrypt
              TEXT

      def execute(paths)
        check_options!
        # Once, up front: a missing secret, or an invalid
        # $EEDBI_DECRYPT_MINIMUM_VERSION, would otherwise fail every item
        # with the same message.
        decrypt_minimum
        secret unless @options[:no_decrypt]
        # Text is printed as each item is checked, JSON once at the end.
        results = paths.map do |path|
          check(path).tap do |result|
            print_text(result) unless json_format?
            result.fetch('warnings', []).each { |warning| stderr.puts "Warning: #{label(result)}: #{warning}" }
          end
        end
        failed = results.count { |result| !result['ok'] }
        if json_format?
          print_json(results, failed)
        elsif failed.positive?
          stdout.puts "#{failed} of #{paths.size} items failed"
        end
        failed.zero? ? 0 : 1
      end

      private

      def reads_item_from_stdin?
        true
      end

      def define_options(opts)
        opts.on('-q', '--quiet', 'Print only failures') do
          @options[:quiet] = true
        end
        define_format_option(opts, 'Output: text or json (default: text)')
        opts.on('--no-decrypt', 'Check without the secret that every value is encrypted,',
                'instead of decrypting') do
          @options[:no_decrypt] = true
        end
      end

      def check_options!
        return unless @options[:no_decrypt] && (@options[:secret_file] || @options[:secret_prompt])

        raise UsageError, '--no-decrypt uses no secret; leave out --secret-file and --secret-prompt'
      end

      def check(path)
        loaded = read_existing(path)
        check_no_byte_order_mark!(loaded)
        versions = loaded.item.except('id').values.map { |field| Crypto.version_of(field) }.grep(Integer).uniq.sort
        check_minimum!(versions)
        @options[:no_decrypt] ? check_encrypted!(loaded.item) : decrypt(loaded)
        Item.validate!(loaded.item)
        check_id_matches_file_name!(loaded)

        result = { 'path' => path, 'ok' => true, 'versions' => versions }
        warning = version_0_warning(loaded)
        warning ? result.merge('warnings' => [warning]) : result
      rescue Error, SystemCallError => e
        { 'path' => path, 'ok' => false, 'error' => Eedbi.item_message(path, e.message).delete_prefix("#{path}: ") }
      end

      def label(result)
        result['path'] == STDIN_ITEM ? 'stdin' : result['path']
      end

      def print_text(result)
        if !result['ok']
          stdout.puts "FAIL  #{label(result)}: #{result['error']}"
        elsif !@options[:quiet]
          stdout.puts "ok    #{label(result)} (#{versions_label(result['versions'])})".sub(' ()', '')
        end
      end

      # knife parses items with yajl, which refuses a byte order mark, so
      # knife upload and data bag from file fail on such a file. eedbi reads
      # it, and leaves it out when it writes the item; this is where it is
      # caught. No eedbi command rewrites an item that did not change, so
      # the fix is outside eedbi.
      def check_no_byte_order_mark!(loaded)
        return unless loaded.bytes&.start_with?("\xEF\xBB\xBF".b)

        message = 'starts with a UTF-8 byte order mark, which knife cannot parse'
        raise Error, message if loaded.path == STDIN_ITEM

        raise Error, "#{message}. Save it as UTF-8 without one, or run: " \
                     "perl -pi -e 's/^\xEF\xBB\xBF// if $. == 1' #{Shellwords.escape(loaded.path)}"
      end

      # knife data bag show and chef-client's data_bag_item decrypt an item
      # only when every value looks like version 1 to 3, and return any other
      # item as it is. Only EncryptedDataBagItem.load decrypts version 0, so
      # the item passes, with a warning. --no-decrypt fails version 0 anyway.
      def version_0_warning(loaded)
        old = Item.version_0_keys(loaded.item)
        return if old.empty?

        command = loaded.path == STDIN_ITEM ? "'eedbi migrate'" : "'eedbi migrate #{loaded.path}'"
        "version 0 values (#{Eedbi.quote_keys(old)}): knife data bag show and chef-client's data_bag_item " \
          'return this item without decrypting it; only EncryptedDataBagItem.load decrypts it. ' \
          "Convert it with #{command}."
      end

      # --quiet leaves out the items that passed; the counts cover all.
      def print_json(results, failed)
        items = @options[:quiet] ? results.reject { |result| result['ok'] } : results
        stdout.puts JSON.pretty_generate('items' => items, 'checked' => results.size, 'failed' => failed)
      end

      # Reports every old version at once, instead of the first value that
      # fails to decrypt.
      def check_minimum!(versions)
        old = versions.select { |version| version < decrypt_minimum }
        raise Error, "uses encryption #{versions_label(old)} (minimum #{decrypt_minimum})" unless old.empty?
      end

      # Reports every plaintext value at once, by key name only, then any
      # value whose version or cipher would make decryption fail. Version 0
      # values fail too: a plaintext string of base64, such as a password
      # from 'openssl rand -base64 32', looks just like one.
      def check_encrypted!(item)
        plain = Item.unencrypted_keys(item)
        raise Error, "not encrypted: #{Eedbi.quote_keys(plain)}" unless plain.empty?

        Item.check_fields!(item)
        old = Item.version_0_keys(item)
        return if old.empty?

        raise Error, "uses encryption version 0 (#{Eedbi.quote_keys(old)}), which plaintext can pass for " \
                     "without the secret. Check it with the secret, or convert it with 'eedbi migrate'."
      end

      def versions_label(versions)
        return '' if versions.empty?

        "#{versions.size == 1 ? 'version' : 'versions'} #{versions.join(', ')}"
      end

      # knife upload rejects an item whose id differs from its file name.
      # Other files are left alone, since knife reads only *.json.
      def check_id_matches_file_name!(loaded)
        return if loaded.path == STDIN_ITEM || !loaded.path.end_with?('.json')

        base = ::File.basename(loaded.path, '.json')
        return if loaded.item['id'] == base

        raise Error, "id must be '#{base}' to match the file name (is '#{loaded.item['id']}'), as knife upload requires"
      end
    end
  end
end
