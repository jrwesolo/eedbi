# frozen_string_literal: true

module Eedbi
  # Dispatches `eedbi COMMAND ...` to a command class.
  #
  # Standard streams are injectable. `interactive:` overrides terminal
  # detection, so tests can drive the editor flow where no terminal exists,
  # such as Windows CI runners. `console:` replaces IO.console for
  # --secret-prompt.
  class CLI
    COMMANDS = [Commands::Edit, Commands::Read, Commands::List, Commands::Write, Commands::Import, Commands::Set, Commands::Unset,
                Commands::Rename, Commands::Migrate, Commands::Check, Commands::Rekey, Commands::NewSecret]
               .to_h { |klass| [klass.command_name, klass] }.freeze

    def initialize(argv, stdin: $stdin, stdout: $stdout, stderr: $stderr, interactive: nil, console: nil)
      @argv = argv.map { |arg| utf8(arg) }
      @context = Commands::Context.new(
        stdin: stdin, stdout: stdout, stderr: stderr,
        stdin_tty: interactive.nil? ? stdin.tty? : interactive,
        stdout_tty: interactive.nil? ? stdout.tty? : interactive,
        console: console ? -> { console } : -> { default_console }
      )
    end

    def run
      invalid = @argv.find { |arg| !arg.valid_encoding? }
      if invalid
        @context.stderr.puts "Argument #{invalid.dump} is not valid UTF-8"
        return 2
      end

      name = @argv.shift
      case name
      when nil then usage_error('Missing command')
      when 'help', '-h', '--help'
        @argv.include?('--version') ? print_version : help(@argv.first)
      when '--version' then print_version
      else run_command(name)
      end
    end

    def self.usage
      width = COMMANDS.keys.map(&:size).max
      commands = COMMANDS.map { |name, klass| "  #{name.ljust(width)}  #{klass.summary}" }
      <<~TEXT
        Usage: eedbi COMMAND [options] ITEM [ARGS...]

        Edit Chef encrypted data bag items.

        Commands:
        #{commands.join("\n")}

        Run 'eedbi help COMMAND' for the options and examples of a command.
        Other options: -h, --help, --version

        stdin carries data, never the secret: the item for write and import,
        the value for set, and the item for read, list and check when ITEM
        is -.

        edit, read, list, write, import, set, unset and rename change or show
        one item; migrate, check and rekey apply to many; new-secret creates
        a secret file.

        Environment:
          #{Secret::ENV_VAR}      Path of the secret file
          #{Commands::Options::DEFAULT_VERSION_VAR}  Version for new items and migrate (default: #{Crypto::DEFAULT_VERSION})
          #{Commands::Options::MINIMUM_VAR}  Refuse values below this version (default: 0)
          #{Commands::Options::NO_PLAINTEXT_VAR}             When set, refuse to show values (read, edit)
          EEDBI_EDITOR, VISUAL, EDITOR   Editor for edit

        Exit status: 0 success, 1 error or failed check, 2 usage error,
        130 interrupted, 141 output pipe closed.
      TEXT
    end

    private

    def help(name)
      return @context.stdout.puts(self.class.usage) || 0 if name.nil? || name == 'help'

      klass = COMMANDS.fetch(name) { return unknown_command(name) }
      @context.stdout.puts klass.new(@context).help
      0
    end

    def run_command(name)
      return option_before_command(name) if name.start_with?('-')

      klass = COMMANDS.fetch(name) { return unknown_command(name) }
      # After a command too, ignoring the rest, as knife and the GNU coding
      # standards do. After --, it is an argument, such as a key.
      return print_version if @argv.take_while { |arg| arg != '--' }.include?('--version')

      klass.new(@context).run(@argv)
    end

    def print_version
      @context.stdout.puts "eedbi #{VERSION}"
      0
    end

    def usage_error(message)
      @context.stderr.puts "#{message}\n\n#{self.class.usage}"
      2
    end

    # The old `eedbi ITEM` form is gone; point at its replacement.
    def unknown_command(name)
      hint = if name.end_with?('.json') then " Did you mean 'eedbi edit #{name}'?"
             elsif name == 'version' then " Did you mean 'eedbi --version'?"
             else Eedbi.suggestion(name, COMMANDS.keys + ['help'])
             end
      @context.stderr.puts "Unknown command '#{name}'.#{hint} Run 'eedbi help' for the list of commands."
      2
    end

    # Options belong to each command, so they go after it, as in
    # `eedbi read -s PATH ITEM`. Point at the command if one follows.
    def option_before_command(option)
      name = @argv.find { |arg| COMMANDS.key?(arg) }
      hint = if name
               "eedbi #{name} [options] #{COMMANDS[name].arguments}\nRun 'eedbi help #{name}' for usage."
             else
               "eedbi COMMAND [options]\nRun 'eedbi help' for the list of commands."
             end
      @context.stderr.puts "Option '#{option}' before the command. Options go after the command: #{hint}"
      2
    end

    # Arguments come in the locale's encoding: US-ASCII under LANG=C, which
    # would make any key with an accent match nothing. Keys are UTF-8, like
    # JSON. Arguments in another encoding, such as a Windows code page, are
    # converted; invalid ones are refused by #run.
    def utf8(arg)
      return arg.dup.force_encoding(Encoding::UTF_8) if [Encoding::US_ASCII, Encoding::BINARY].include?(arg.encoding)

      arg.encode(Encoding::UTF_8)
    rescue EncodingError
      arg.dup.force_encoding(Encoding::UTF_8)
    end

    def default_console
      require 'io/console'
      IO.console
    end
  end
end
