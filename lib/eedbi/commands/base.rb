# frozen_string_literal: true

module Eedbi
  # One class per subcommand. Each defines its name, summary, description
  # and options, and implements #execute(arguments).
  module Commands
    # Standard streams and terminal state, shared by all commands.
    # `console` is called only when a secret is prompted for.
    Context = Struct.new(:stdin, :stdout, :stderr, :stdin_tty, :stdout_tty, :console, keyword_init: true)

    # Option parsing, secret loading and saving, shared by all commands.
    class Base
      include Options

      # An ITEM of - reads the item from stdin (read, list and check only).
      STDIN_ITEM = '-'

      class << self
        attr_reader :summary, :description, :arguments, :examples

        def command_name
          name.split('::').last.downcase
        end

        private

        # `arguments` is shown in the usage line: 'ITEM' for exactly one item,
        # 'ITEM [KEY]' for one item and maybe a key, 'ITEM...' for one or
        # more. Commands taking anything else override #check_arguments!.
        # `examples` end the help.
        def command(summary:, arguments:, description:, examples:)
          @summary = summary
          @arguments = arguments
          @description = description
          @examples = examples
        end
      end

      def initialize(context)
        @context = context
        @options = {}
      end

      def run(argv)
        arguments = parse(argv)
        return 0 if @options[:help]

        check_arguments!(arguments)
        # Before any item is read: commands on many items report each item's
        # errors separately, which would repeat this one for every item.
        Secret.check_options!(file: @options[:secret_file], prompt: @options[:secret_prompt])
        check_item_from_stdin!(arguments)
        arguments = Store.distinct(arguments) if self.class.arguments == 'ITEM...'
        naming_item(arguments.first) { execute(arguments) }
      end

      def help
        parser.to_s
      end

      private

      def stdin = @context.stdin
      def stdout = @context.stdout
      def stderr = @context.stderr

      def name
        self.class.command_name
      end

      # Command specific options. Override to add options.
      def define_options(opts); end

      # Whether ITEM may be - to read the item itself from stdin. Override.
      def reads_item_from_stdin?
        false
      end

      # Whether values below the decrypt minimum version may be read.
      # Overridden by migrate, whose job is upgrading them.
      def reads_below_minimum?
        false
      end

      def parser
        @parser ||= OptionParser.new do |opts|
          # Only exact option names, so that a typo such as --sec is an error
          # instead of being expanded to some other option.
          opts.require_exact = true
          # OptionParser adds shell completion options to every parser,
          # which print and exit on their own, and its own --version.
          %w[version *-completion-bash *-completion-zsh].each { |option| opts.base.long.delete(option) }
          opts.banner = "Usage: eedbi #{name} [options] #{self.class.arguments}"
          indented(opts, '', self.class.description)
          opts.separator ''
          opts.separator 'Options:'
          define_options(opts)
          define_secret_options(opts)
          define_minimum_option(opts) unless reads_below_minimum?
          opts.on('-h', '--help', 'Show this help') do
            @options[:help] = true
            stdout.puts opts
          end
          # Handled by CLI before the command runs; listed for the help.
          opts.on('--version', 'Show the version of eedbi')
          indented(opts, 'Examples:', self.class.examples)
        end
      end

      # A blank line, `heading` if any, then `text` indented by two spaces.
      def indented(opts, heading, text)
        opts.separator ''
        opts.separator heading unless heading.empty?
        text.each_line { |line| opts.separator "  #{line.chomp}".rstrip }
      end

      # Everything after -- is an argument, such as a key starting with -.
      # It is split off here because OptionParser before Ruby 3.4 crashes on
      # -- when require_exact is set.
      #
      # permute, not parse: parse stops at the first argument when
      # $POSIXLY_CORRECT is set, which would turn every option after ITEM,
      # where the examples put them, into an argument.
      def parse(argv)
        index = argv.index('--')
        return parser.permute(argv) unless index

        parser.permute(argv[0...index]) + argv[(index + 1)..]
      rescue OptionParser::ParseError => e
        # Before Ruby 3.4, did_you_mean adds its own suggestion as a second line.
        message = e.message.lines.first.chomp
        suggestion = option_suggestion(e)
        message = "#{message}.#{suggestion}" unless suggestion.empty?
        raise UsageError, "#{message}\nRun 'eedbi help #{name}' for usage."
      end

      def option_suggestion(error)
        word = error.args.first.to_s.sub(/=.*/m, '')
        return '' unless error.is_a?(OptionParser::InvalidOption) && word.start_with?('--')

        Eedbi.suggestion(word, parser.top.long.keys.map { |option| "--#{option}" })
      end

      def check_arguments!(arguments)
        many = self.class.arguments == 'ITEM...'
        if arguments.empty?
          raise UsageError, "eedbi #{name} needs #{many ? 'at least one item' : 'an item'}\n" \
                            "Run 'eedbi help #{name}' for usage."
        end
        max = { 'ITEM' => 1, 'ITEM [KEY]' => 2 }[self.class.arguments]
        return unless max && arguments.size > max

        raise UsageError, "eedbi #{name} takes one item (#{received(arguments)})" if max == 1

        raise UsageError, "eedbi #{name} takes ITEM and an optional KEY (#{received(arguments)})"
      end

      # For messages about the number of arguments: "received 1 argument".
      def received(arguments)
        "received #{arguments.size} #{arguments.size == 1 ? 'argument' : 'arguments'}"
      end

      # stdin carries only items and values, never the secret, so the only
      # possible clash is the same item asked for twice. Only items count: a
      # KEY may be named -.
      def check_item_from_stdin!(arguments)
        items = self.class.arguments.start_with?('ITEM...') ? arguments : arguments.first(1)
        count = items.count(STDIN_ITEM)
        return if count.zero?
        raise UsageError, stdin_item_refusal unless reads_item_from_stdin?
        raise UsageError, 'Only one item can come from stdin' if count > 1
        raise Error, "eedbi #{name} reads the item from stdin (-), but stdin is a terminal" if @context.stdin_tty
      end

      # Why ITEM cannot be - for this command. write, import and set read
      # stdin without it, since ITEM is the file they write.
      def stdin_item_refusal
        return "Only read, list and check can read the item from stdin (-), not #{name}" unless stdin_usage

        "eedbi #{name} reads stdin without -; ITEM is the file it writes: #{stdin_usage}"
      end

      # How to pipe stdin in, for commands that read it themselves.
      def stdin_usage; end

      # Commands on one item start every error with it, so that a script
      # running many of them can tell which item failed. Commands on many
      # items name each failing item themselves, usage errors are about the
      # command line, and an item from stdin has no file name.
      def naming_item(path)
        return yield if self.class.arguments.start_with?('ITEM...') || path == STDIN_ITEM

        begin
          yield
        # A closed output pipe is about the output, not the item.
        rescue UsageError, Errno::EPIPE
          raise
        rescue Error, SystemCallError => e
          raise Error, Eedbi.item_message(path, e.message)
        end
      end

      def secret
        @secret ||= Secret.load(file: @options[:secret_file], prompt: @options[:secret_prompt],
                                console: @options[:secret_prompt] ? @context.console.call : nil,
                                stderr: stderr)
      end

      def decrypt(loaded, key = secret)
        Item.decrypt(loaded.item, key, minimum: reads_below_minimum? ? 0 : decrypt_minimum)
      rescue BelowMinimumError => e
        raise Error, "#{loaded.path}: #{e.message}. 'eedbi migrate' can upgrade it."
      rescue NotEncryptedError => e
        raise Error, "#{loaded.path}: unable to decrypt (#{e.message}). Is the item encrypted?"
      rescue DecryptionError => e
        raise Error, "#{loaded.path}: unable to decrypt (#{e.message}). Is this the right secret?"
      end

      def read_existing(path)
        return Store.read_stream(stdin) if path == STDIN_ITEM

        loaded = Store.read(path)
        raise Error, "#{path}: file not found#{json_hint(path)}" unless loaded.exist?

        loaded
      end

      # For commands that create the item when it does not exist. knife only
      # picks up data_bags/BAG/ITEM.json, so a new item without the
      # extension would be silently left out.
      def read_or_new(path)
        loaded = Store.read(path)
        return loaded if loaded.exist? || path.end_with?('.json')
        raise Error, "#{path}: file not found#{json_hint(path)}" if ::File.exist?("#{path}.json")

        raise Error, "New items need a .json file name, as knife expects: #{path}.json"
      end

      def json_hint(path)
        ::File.exist?("#{path}.json") ? ". Did you mean #{path}.json?" : ''
      end

      # Validates, encrypts and writes `after_plain` over `loaded`. Returns
      # :saved, or :unchanged when there was nothing to save; with --dry-run
      # nothing is written either way. When the file changed on disk since
      # it was read, `on_conflict` decides: true to overwrite, false to
      # discard.
      def save(loaded, before_plain, after_plain, on_conflict:)
        Item.validate!(after_plain)
        warn_id_mismatch(after_plain, loaded.path)
        return :unchanged unless Changes.any?(before_plain, after_plain)

        check_no_downgrade!(loaded, Changes.changed_keys(before_plain, after_plain))
        return :saved if dry_run?

        encrypted = Item.update(after_plain, secret, before_plain: before_plain, before_encrypted: loaded.item,
                                                     requested: @options[:encrypt_version], default: default_version)
        if loaded.changed_on_disk? && !on_conflict.call
          raise Error, 'Changes discarded; the file was left as it is on disk.'
        end

        Store.write_atomic(loaded.path, Store.dump(encrypted))
        :saved
      end

      # Writes `item` over `loaded` as it is, for the commands that encrypt
      # nothing.
      def write_item(loaded, item)
        if loaded.changed_on_disk?
          raise Error, "#{loaded.path} changed on disk while eedbi was running. Nothing was written."
        end

        Store.write_atomic(loaded.path, Store.dump(item))
      end

      # Starts with the item, like errors, so that a script running many
      # commands can tell which item each line is about.
      def report_save(loaded, result, before_plain, after_plain)
        new_item = !loaded.exist?
        message = if result == :unchanged then 'no changes'
                  elsif dry_run? then "would #{Changes.describe(before_plain, after_plain, new_item: new_item)}"
                  else Changes.describe(before_plain, after_plain, new_item: new_item, done: true)
                  end
        stdout.puts "#{loaded.path}: #{message}"
      end

      # Only for *.json, since knife reads no other file.
      def warn_id_mismatch(item, path)
        return unless path.end_with?('.json')

        base = ::File.basename(path, '.json')
        return if item['id'] == base

        stderr.puts "Warning: id '#{item['id']}' does not match file name '#{base}'"
      end
    end
  end
end
