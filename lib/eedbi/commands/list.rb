# frozen_string_literal: true

module Eedbi
  module Commands
    # Lists the keys of an item, without decrypting anything.
    class List < Base
      command summary: 'List the keys of an item',
              arguments: 'ITEM',
              description: <<~TEXT,
                Lists the keys of ITEM, one per line, ready to pass to read,
                edit, set or unset. The id is left out, since it is not
                encrypted. --versions adds the encryption version of each
                value ('unencrypted' for a plain value). Nothing is decrypted,
                so no secret is needed. ITEM can be - to read the item from
                stdin.

                --format json prints a list of the keys, or with --versions an
                object of keys and versions, with null for a plain value. Use
                it for keys that contain a newline.
              TEXT
              examples: <<~TEXT
                eedbi list data_bags/db/mysql.json
                eedbi list data_bags/db/mysql.json --versions
                eedbi list data_bags/db/mysql.json --format json
              TEXT

      def execute((path))
        item = read_existing(path).item
        keys = item.keys - ['id']
        if json_format?
          document = @options[:versions] ? keys.to_h { |key| [key, Crypto.version_of(item[key])] } : keys
          stdout.puts JSON.pretty_generate(document)
        elsif @options[:versions]
          width = keys.map(&:size).max
          keys.each { |key| stdout.puts "#{key.ljust(width)}  #{version_label(item[key])}" }
        else
          keys.each { |key| stdout.puts key }
        end
        0
      end

      private

      def reads_item_from_stdin?
        true
      end

      def define_options(opts)
        opts.on('--versions', 'Also print the encryption version of each value') do
          @options[:versions] = true
        end
        define_format_option(opts, 'Output: text or json (default: text)')
      end

      # No value is decrypted.
      def define_secret_options(opts); end
      def define_minimum_option(opts); end

      def version_label(field)
        version = Crypto.version_of(field)
        if version.nil? then 'unencrypted'
        elsif Crypto::DECRYPT_VERSIONS.any? { |v| v.eql?(version) } then version.to_s
        else "unsupported (#{version.inspect})"
        end
      end
    end
  end
end
