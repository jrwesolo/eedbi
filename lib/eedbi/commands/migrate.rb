# frozen_string_literal: true

module Eedbi
  module Commands
    # Converts items to another encryption version, with the same secret.
    class Migrate < Base
      include Rewrite

      command summary: 'Convert items to another encryption version',
              arguments: 'ITEM...',
              description: <<~TEXT,
                Converts every value of each ITEM to --encrypt-version, by
                default $EEDBI_DEFAULT_ENCRYPT_VERSION, else 3. Values already
                in that version keep their ciphertext. Lowering a version
                weakens the encryption, so it needs --allow-downgrade. Values
                below the decrypt minimum version are read, since upgrading
                them is the point.

                Nothing is written unless every item can be converted. Each
                item is reported as it is written; a write that fails, as
                when the file changed meanwhile, does not stop the others.
                Items already converted are left as they are, so running
                the same command again finishes the job.
              TEXT
              examples: <<~TEXT
                eedbi migrate data_bags/*/*.json --dry-run
                eedbi migrate data_bags/*/*.json
                eedbi migrate data_bags/legacy/*.json --encrypt-version 2
              TEXT

      def execute(paths)
        note_minimum
        version = @options.fetch(:encrypt_version) { default_version }
        # Once, up front: a missing secret would otherwise fail every item
        # with the same message.
        secret

        rewrite_all(paths) { |loaded| migrate(loaded, decrypt(loaded), version) }
        0
      end

      private

      def reads_below_minimum?
        true
      end

      def define_options(opts)
        define_encrypt_version_option(opts, 'Encryption version to convert to: 1, 2 or 3',
                                      "(default: $#{DEFAULT_VERSION_VAR}, else #{Crypto::DEFAULT_VERSION})")
        opts.on('--allow-downgrade', 'Allow converting values to an older encryption version') do
          @options[:allow_downgrade] = true
        end
        define_dry_run_option(opts)
      end

      # The item converted, or nil to leave it as it is, and the line that
      # reports it.
      def migrate(loaded, plain, version)
        check_downgrade!(loaded.item, version)
        before = versions(loaded.item)
        return [nil, "#{loaded.path}: no values to convert"] if before.empty?
        return [nil, "#{loaded.path}: already version #{version}"] if before == [version]

        verb = dry_run? ? 'would convert' : 'converted'
        [Item.encrypt(plain, secret, version, before_plain: plain, before_encrypted: loaded.item),
         "#{loaded.path}: #{verb} version #{before.join(', ')} -> #{version}"]
      end

      def check_downgrade!(item, version)
        return if @options[:allow_downgrade]

        values = item.except('id')
        newer = values.select { |_, field| Crypto.version_of(field).to_i > version }
        return if newer.empty?

        which = newer.size == values.size ? 'every value' : Eedbi.quote_keys(newer.keys)
        from = newer.values.map { |field| Crypto.version_of(field) }.uniq.sort.join(', ')
        raise Error, "would lower #{which} from version #{from} to #{version}. " \
                     'Pass --allow-downgrade to lower versions.'
      end

      def note_minimum
        minimum = decrypt_minimum
        return if minimum.zero?

        stderr.puts "Note: migrate reads values below the decrypt minimum version (#{minimum}) to upgrade them"
      end

      def versions(item)
        item.except('id').values.map { |field| Crypto.version_of(field) }.uniq.sort
      end
    end
  end
end
