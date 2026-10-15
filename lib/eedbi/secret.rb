# frozen_string_literal: true

module Eedbi
  # Finding and reading the encrypted data bag secret.
  module Secret
    ENV_VAR = 'ENCRYPTED_DATA_BAG_SECRET'

    # Searched in order when neither --secret-file, --secret-prompt nor
    # $ENCRYPTED_DATA_BAG_SECRET is given. Without a home directory, as for
    # some service accounts, ~/.chef is left out rather than read as /.chef.
    def self.candidates(home)
      [
        './encrypted_data_bag_secret',
        (::File.join(home, '.chef', 'encrypted_data_bag_secret') unless home.empty?),
        WINDOWS ? 'C:/chef/encrypted_data_bag_secret' : '/etc/chef/encrypted_data_bag_secret'
      ].compact.freeze
    end

    CANDIDATES = candidates(HOME)

    PROMPT = 'Encrypted data bag secret: '

    # CANDIDATES as shown in help, with the home directory as ~.
    def self.candidate_labels
      CANDIDATES.map { |path| HOME.empty? ? path : path.sub(/\A#{Regexp.escape(HOME)}/, '~') }
    end

    module_function

    # `console` is an IO that can read without echo (IO.console), used for
    # --secret-prompt. It reads from the terminal even when stdin is piped,
    # so `eedbi write ITEM --secret-prompt < plain.json` works.
    #
    # stdin is never read here: it carries only items and values. A path such
    # as /dev/stdin or <(command) is read like any other file.
    def load(file: nil, prompt: false, console: nil, stderr: $stderr)
      check_options!(file: file, prompt: prompt)
      return from_prompt(console) if prompt

      # A set but missing $ENCRYPTED_DATA_BAG_SECRET is an error rather than
      # a reason to fall back to another, possibly different, secret.
      env = ENV.fetch(ENV_VAR, '')
      return read_file(file, stderr: stderr) if file
      return read_file(env, stderr: stderr, source: "$#{ENV_VAR}") unless env.empty?

      found = CANDIDATES.find { |candidate| ::File.exist?(candidate) }
      return read_file(found, stderr: stderr) if found

      raise Error, "No secret found. Use --secret-file or --secret-prompt, set $#{ENV_VAR}, " \
                   "or create one of: #{CANDIDATES.join(', ')}"
    end

    def check_options!(file:, prompt:)
      raise UsageError, 'Choose one of --secret-file and --secret-prompt' if file && prompt
    end

    def read_file(path, stderr: $stderr, source: nil)
      check_not_stdin!(path)
      raise Error, "Secret file not found: #{path}#{" (from #{source})" if source}" unless ::File.exist?(path)
      raise Error, "Secret file is a directory: #{path}" if ::File.directory?(path)

      invalid = "Secret file is not valid UTF-8, which Chef cannot load: #{path}"
      secret = utf8(::File.read(path, encoding: Encoding::UTF_8), invalid)
      raise Error, "Secret file is empty: #{path}" if secret.empty?

      warn_if_world_readable(path, stderr)
      warn_if_crlf_inside(path, stderr)
      secret
    end

    # Read as Chef reads it: IO.read(path).strip, as UTF-8, which Chef sets
    # as the default external encoding whatever the locale. Text mode, as
    # in Chef, so that on Windows CRLF becomes LF there too. A secret that
    # is not valid UTF-8 makes Chef fail with an encoding error; refusing
    # it here keeps eedbi from encrypting items no node could decrypt.
    def utf8(text, message)
      text = text.dup.force_encoding(Encoding::UTF_8)
      raise Error, message unless text.valid_encoding?

      text.strip
    end

    # - used to mean stdin. Say where the secret can come from instead of
    # reporting a missing file named -.
    def check_not_stdin!(path)
      return unless path == '-'

      raise UsageError, 'The secret cannot come from stdin (-), which carries only items and values. ' \
                        "Use a file, $#{ENV_VAR}, a prompt, or a path such as <(command)."
    end

    # With `confirm`, the secret must be typed twice. Worth it for a new
    # secret, where a typo would lock everyone out of the rekeyed items.
    def from_prompt(console, prompt: PROMPT, confirm: false)
      raise Error, 'Prompting for a secret needs a terminal' unless console

      invalid = 'The secret typed is not valid UTF-8, which Chef cannot load'
      secret = utf8(console.getpass(prompt).to_s, invalid)
      raise Error, 'The secret is empty' if secret.empty?
      if confirm && utf8(console.getpass("Repeat #{prompt[0].downcase}#{prompt[1..]}").to_s, invalid) != secret
        raise Error, 'The secrets do not match'
      end

      secret
    end

    # Like ssh does for private keys, but only a warning: a secret every user
    # on the machine can read protects nothing from them. Group read access
    # is common and deliberate (for example root:chef 0640), so it is fine.
    # Pipes, such as <(command), have no meaningful mode.
    def warn_if_world_readable(path, stderr)
      return if WINDOWS || !::File.file?(path)

      mode = ::File.stat(path).mode & 0o777
      return if mode.nobits?(0o004)

      stderr.puts format('Warning: %<path>s is readable by every user on this system (mode %<mode>04o). ' \
                         'Restrict it with: chmod o-r %<path>s', path: path, mode: mode)
    end

    # Chef reads the secret in text mode, which turns CRLF into LF on
    # Windows only, so a secret with CRLF line breaks inside gives another
    # key there than on other systems, with knife as with eedbi. Read again
    # in binary to see them on Windows too; a pipe cannot be read twice,
    # but <(command) output is not from a Windows editor anyway.
    def warn_if_crlf_inside(path, stderr)
      return unless ::File.file?(path) && ::File.binread(path).strip.include?("\r\n")

      stderr.puts "Warning: #{path} has CRLF line breaks inside the secret. Chef reads them as LF on Windows " \
                  'and as CRLF elsewhere, so the same file gives a different key. Put the secret on one line.'
    end
  end
end
