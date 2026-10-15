# frozen_string_literal: true

module Eedbi
  module Commands
    # Options shared by several commands, and the environment variables that
    # supply their defaults.
    module Options
      DEFAULT_VERSION_VAR = 'EEDBI_DEFAULT_ENCRYPT_VERSION'
      MINIMUM_VAR = 'EEDBI_DECRYPT_MINIMUM_VERSION'
      NO_PLAINTEXT_VAR = 'EEDBI_NO_PLAINTEXT'

      private

      def define_secret_options(opts)
        opts.on('-s', '--secret-file PATH',
                'Encrypted data bag secret file. Default:',
                "$#{Secret::ENV_VAR}",
                *Secret.candidate_labels.map { |candidate| "then #{candidate}" }) do |path|
          @options[:secret_file] = path
        end
        opts.on('--secret-prompt', 'Read the secret from the terminal, without echo') do
          @options[:secret_prompt] = true
        end
      end

      def define_minimum_option(opts)
        opts.on('--decrypt-minimum-version VERSION', %w[0 1 2 3],
                'Refuse values below this encryption version',
                "(default: $#{MINIMUM_VAR}, else 0)") do |version|
          @options[:decrypt_minimum] = Integer(version)
        end
      end

      def define_encrypt_version_option(opts, *description)
        opts.on('--encrypt-version VERSION', %w[1 2 3], *description) do |version|
          @options[:encrypt_version] = Integer(version)
        end
      end

      # For edit, write and set, which convert only what they write.
      def define_write_version_option(opts)
        define_encrypt_version_option(opts, 'Encryption version for changed and new values: 1, 2 or 3.',
                                      "Default: each value's own version. New keys and version 0",
                                      "values take the item's highest version, else",
                                      "$#{DEFAULT_VERSION_VAR}, else #{Crypto::DEFAULT_VERSION}")
      end

      # --encrypt-version applies to the values a command writes anyway, and
      # never lowers one: weakening values is left to migrate, where it is
      # deliberate and covers the whole item.
      def check_no_downgrade!(loaded, keys)
        requested = @options[:encrypt_version]
        return unless requested

        item = loaded.item
        newer = keys.select { |key| Crypto.version_of(item[key]).to_i > requested }
        return if newer.empty?

        from = newer.map { |key| Crypto.version_of(item[key]) }.uniq.sort.join(', ')
        raise Error, "#{loaded.path}: --encrypt-version #{requested} would lower #{Eedbi.quote_keys(newer)} " \
                     "from version #{from}. To lower versions, use " \
                     "'eedbi migrate --encrypt-version #{requested} --allow-downgrade'."
      end

      # For write, import and set, which read from stdin unless given a file.
      def define_from_file_option(opts, description)
        opts.on('--from-file PATH', description) do |path|
          @options[:from_file] = path
        end
      end

      # Whether the input is the implied stdin: no --from-file. --from-file -
      # reads stdin too, but as a file, exactly.
      def reads_stdin?
        @options[:from_file].nil?
      end

      def input_label
        file = @options[:from_file]
        file.nil? || file == '-' ? 'stdin' : file
      end

      # The bytes of PATH, or of stdin for -, as UTF-8. Binary mode, so that
      # Windows does not turn CRLF into LF.
      def read_from_file(path)
        if path == '-'
          raise Error, "eedbi #{name} reads stdin (--from-file -), but stdin is a terminal" if @context.stdin_tty

          stdin.binmode if stdin.respond_to?(:binmode)
          return stdin.read.to_s.force_encoding(Encoding::UTF_8)
        end
        raise Error, "Input file not found: #{path}" unless ::File.exist?(path)

        Store.check_not_directory!(path)
        ::File.binread(path).force_encoding(Encoding::UTF_8)
      end

      def define_dry_run_option(opts)
        opts.on('--dry-run', 'Show what would change, without writing anything') do
          @options[:dry_run] = true
        end
      end

      # Output for scripts. Text stays the default, for people.
      def define_format_option(opts, *description)
        opts.on('--format FORMAT', %w[text json], *description) do |format|
          @options[:format] = format
        end
      end

      def json_format?
        @options[:format] == 'json'
      end

      def dry_run?
        @options[:dry_run]
      end

      # The version eedbi picks when it has to choose: for new items, for
      # items in version 0, which cannot be written, and as the default
      # target of migrate. Otherwise an item keeps its version; converting
      # it takes migrate.
      def default_version
        env_version(DEFAULT_VERSION_VAR, %w[1 2 3]) || Crypto::DEFAULT_VERSION
      end

      def decrypt_minimum
        @options.fetch(:decrypt_minimum) { env_version(MINIMUM_VAR, %w[0 1 2 3]) || 0 }
      end

      # $EEDBI_NO_PLAINTEXT, set to anything, makes the commands that show
      # values refuse, for environments such as AI agents and CI where
      # output is captured. Like NO_COLOR, any value counts, so that a
      # mistyped one errs on the safe side. No option overrides it.
      def refuse_plaintext!(alternatives)
        return if ENV.fetch(NO_PLAINTEXT_VAR, '').empty?

        raise Error, "eedbi #{name} shows plaintext, which $#{NO_PLAINTEXT_VAR} disables. #{alternatives}"
      end

      def env_version(var, allowed)
        value = ENV.fetch(var, '').strip
        return if value.empty?
        return Integer(value) if allowed.include?(value)

        raise Error, "Invalid $#{var} '#{value}': use #{allowed.join(', ')}"
      end
    end
  end
end
