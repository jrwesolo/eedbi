# frozen_string_literal: true

module Eedbi
  module Commands
    # Creates a new random secret file.
    class NewSecret < Base
      command summary: 'Create a new secret file',
              arguments: 'PATH',
              description: <<~TEXT,
                Writes a new random secret to PATH, with mode 0600: 512 random
                bytes, base64 encoded on one line, as Chef recommends
                (openssl rand -base64 512 | tr -d '\\r\\n'). PATH must not
                exist: a secret is never overwritten, since the items
                encrypted with it could no longer be read. The secret is
                never printed.

                To change the secret of existing items, pass the new file to
                'eedbi rekey --new-secret-file'.
              TEXT
              examples: <<~TEXT
                eedbi new-secret ~/.chef/encrypted_data_bag_secret
                eedbi new-secret new_secret
                eedbi rekey data_bags/*/*.json --new-secret-file new_secret
              TEXT

      # Random bytes before base64, as in Chef's documentation. The key is
      # SHA-256 of the secret, so any 32 random bytes or more give the same
      # strength.
      BYTES = 512

      def self.command_name = 'new-secret'

      def execute((path))
        if ::File.exist?(path) || ::File.symlink?(path)
          raise Error, "#{path} already exists. A secret is never overwritten, since the items " \
                       'encrypted with it could no longer be read; remove it first if you mean to.'
        end
        Store.check_writable!(path)

        flags = ::File::WRONLY | ::File::CREAT | ::File::EXCL | ::File::BINARY
        ::File.open(path, flags, 0o600) { |file| file.write(SecureRandom.base64(BYTES)) }
        stdout.puts "#{path}: created a new secret"
        0
      end

      private

      def check_arguments!(arguments)
        raise UsageError, "eedbi new-secret needs a PATH\nRun 'eedbi help new-secret' for usage." if arguments.empty?
        return if arguments.size == 1

        raise UsageError, "eedbi new-secret takes one PATH (#{received(arguments)})"
      end

      # The secret is never printed, so PATH cannot be - for stdout.
      def check_item_from_stdin!(arguments)
        return unless arguments.first == STDIN_ITEM

        raise UsageError, 'eedbi new-secret writes a file and never prints the secret: give a PATH'
      end

      # No secret is read.
      def define_secret_options(opts); end
      def define_minimum_option(opts); end
    end
  end
end
