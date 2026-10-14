# frozen_string_literal: true

module Eedbi
  module Commands
    # Prints a decrypted item, or one value from it.
    class Read < Base
      command summary: 'Print a decrypted item, or one value',
              arguments: 'ITEM [KEY]',
              description: <<~TEXT,
                Prints ITEM decrypted, as JSON. With KEY, prints only that
                value: a string followed by one newline, so that
                'eedbi read ITEM KEY | eedbi set ITEM KEY' keeps it exactly,
                and anything else as JSON. ITEM can be - to read the item from
                stdin.

                --digest prints a digest of each value instead of the value:
                an HMAC keyed by the secret, the same for equal values under
                one secret, and useless without it. It shows whether values
                changed, or are equal, without showing them. To list the keys
                without the secret, use 'eedbi list'.

                When $EEDBI_NO_PLAINTEXT is set, only --digest is allowed.
              TEXT
              examples: <<~TEXT
                eedbi read data_bags/db/mysql.json
                eedbi read data_bags/db/mysql.json password
                eedbi read data_bags/db/mysql.json --digest
                git show main:data_bags/db/mysql.json | eedbi read -
              TEXT

      def execute((path, key))
        unless @options[:digest]
          refuse_plaintext!("To compare values, use 'eedbi read ITEM --digest'; to see the keys, 'eedbi list ITEM'.")
        end

        loaded = read_existing(path)
        plain = decrypt(loaded)
        raise Error, "#{path}: no key #{Eedbi.quote_key(key)}" if key && !plain.key?(key)

        stdout.print key ? format_value(key, plain[key]) : "#{JSON.pretty_generate(digested(plain))}\n"
        0
      end

      private

      def reads_item_from_stdin?
        true
      end

      def define_options(opts)
        opts.on('--digest', 'Print a digest of each value instead of the value') do
          @options[:digest] = true
        end
      end

      def digested(plain)
        return plain unless @options[:digest]

        plain.to_h { |key, value| [key, key == 'id' ? value : Item.digest(value, secret)] }
      end

      # Always one newline after a string, even one that ends with a newline
      # already, as jq -r does: set removes exactly one. The id is not
      # encrypted, so --digest shows it as is, as in the whole item.
      def format_value(key, value)
        return "#{Item.digest(value, secret)}\n" if @options[:digest] && key != 'id'

        case value
        when String then "#{value}\n"
        when Hash, Array then "#{JSON.pretty_generate(value)}\n"
        else "#{JSON.generate(value)}\n"
        end
      end
    end
  end
end
