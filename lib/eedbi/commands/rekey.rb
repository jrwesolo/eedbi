# frozen_string_literal: true

module Eedbi
  module Commands
    # Re-encrypts items with a new secret.
    class Rekey < Base
      include Rewrite

      command summary: 'Re-encrypt items with a new secret',
              arguments: 'ITEM...',
              description: <<~TEXT,
                Decrypts each ITEM with the current secret and encrypts every
                value with the new one, in the encryption version it is in
                now. Version 0 cannot be written, so items using it need
                'eedbi migrate' first. Afterwards, deploy the new secret
                everywhere the items are read before retiring the old one.

                Nothing is written unless every item can be re-encrypted.
                Each item is reported as it is written; a write that fails,
                as when the file changed meanwhile, does not stop the
                others. Items that already decrypt with the new secret are
                left as they are, so running the same command again
                finishes the job.
              TEXT
              examples: <<~TEXT
                eedbi rekey data_bags/db/*.json --new-secret-file new_secret --dry-run
                eedbi rekey data_bags/db/*.json --new-secret-file new_secret
                eedbi rekey data_bags/db/*.json --secret-prompt --new-secret-prompt
              TEXT

      NEW_PROMPT = 'New encrypted data bag secret: '

      def execute(paths)
        check_new_secret_options!
        # Once, up front: an invalid $EEDBI_DECRYPT_MINIMUM_VERSION would
        # otherwise fail every item with the same message.
        decrypt_minimum
        # The current secret first, so that a wrong one is found before the
        # new one is typed twice.
        current = secret
        @new_secret = load_new_secret
        raise Error, 'The new secret is the same as the current one' if @new_secret == current

        rewrite_all(paths) { |loaded| rekey_item(loaded) }
        0
      end

      private

      # The item encrypted with the new secret, or nil to leave it as it
      # is, and the line that reports it.
      def rekey_item(loaded)
        plain = current_plain(loaded)
        return [nil, "#{loaded.path}: already uses the new secret"] if plain.nil?
        return [nil, "#{loaded.path}: no values to encrypt"] if plain.except('id').empty?

        check_writable_versions!(loaded)
        rekeyed = Item.rekey(plain, loaded.item, @new_secret)
        # Never write an item the new secret cannot read back.
        raise Error, "#{loaded.path}: verification failed" unless Item.decrypt(rekeyed, @new_secret) == plain

        [rekeyed, "#{loaded.path}: #{dry_run? ? 'would be encrypted' : 'encrypted'} with the new secret"]
      end

      def define_options(opts)
        opts.on('--new-secret-file PATH', 'File with the secret to encrypt with from now on') do |path|
          @options[:new_secret_file] = path
        end
        opts.on('--new-secret-prompt', 'Type the new secret, twice, without echo') do
          @options[:new_secret_prompt] = true
        end
        define_dry_run_option(opts)
      end

      # The item decrypted with the current secret, or nil when it decrypts
      # with the new one instead, as after an interrupted run, so that
      # running rekey again finishes the job. A wrong secret never passes
      # the integrity checks of versions 2 and 3, and effectively never the
      # padding and JSON checks of version 1. Version 0 values, decrypted
      # as YAML, have no such check, so an item with any is never skipped.
      def current_plain(loaded)
        decrypt(loaded)
      rescue Error => e
        raise unless Item.version_0_keys(loaded.item).empty?
        raise e unless decrypts_with_new_secret?(loaded)

        nil
      end

      def decrypts_with_new_secret?(loaded)
        decrypt(loaded, @new_secret)
        true
      rescue Error
        false
      end

      # rekey changes the secret and nothing else, and version 0 can only be
      # read, so converting is left to migrate.
      def check_writable_versions!(loaded)
        old = Item.version_0_keys(loaded.item)
        return if old.empty?

        raise Error, "uses encryption version 0 (#{Eedbi.quote_keys(old)}), which cannot be written. " \
                     "Run 'eedbi migrate #{loaded.path}' first."
      end

      def check_new_secret_options!
        file = @options[:new_secret_file]
        prompt = @options[:new_secret_prompt]
        raise UsageError, 'Choose one of --new-secret-file and --new-secret-prompt' if file && prompt

        # Before the current secret is read, as usage errors are.
        Secret.check_not_stdin!(file) if file
        return if file || prompt

        raise UsageError, "eedbi rekey needs --new-secret-file or --new-secret-prompt\n" \
                          "Run 'eedbi help rekey' for usage."
      end

      def load_new_secret
        if @options[:new_secret_prompt]
          return Secret.from_prompt(@context.console.call, prompt: NEW_PROMPT, confirm: true)
        end

        Secret.read_file(@options[:new_secret_file], stderr: stderr)
      end
    end
  end
end
