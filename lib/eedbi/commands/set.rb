# frozen_string_literal: true

module Eedbi
  module Commands
    # Sets one value of an item without opening an editor.
    class Set < Base
      command summary: 'Set one value of an item',
              arguments: 'ITEM KEY',
              description: <<~TEXT,
                Sets KEY in ITEM to a value read from stdin, without one
                trailing newline. When stdin is a terminal, the value is typed
                instead, twice and without echo. --from-file reads the value
                from a file exactly as it is, including any trailing newline;
                --from-file - does the same with stdin. The value is a string;
                --json-value parses it as JSON instead. An empty value from
                stdin or a file is refused unless --allow-empty. Creates ITEM
                if it does not exist. Other values keep their ciphertext.

                Only the values that change are encrypted again, each in its
                own version unless --encrypt-version is given; 'eedbi migrate'
                converts whole items. Version 0 cannot be written, so changed
                version 0 values take the item's highest version.
              TEXT
              examples: <<~TEXT
                printf %s "$PASSWORD" | eedbi set data_bags/db/mysql.json password
                eedbi set data_bags/db/mysql.json password      # typed, hidden
                echo 5432 | eedbi set data_bags/db/mysql.json port --json-value
                eedbi set data_bags/web/tls.json certificate --from-file cert.pem
              TEXT

      def execute((path, key))
        @key = key
        raise UsageError, "The id is not encrypted and cannot be set; use 'eedbi edit' to change it" if key == 'id'
        if @options[:json_value] && @options[:allow_empty]
          raise UsageError, '--allow-empty and --json-value cannot be combined: an empty value is not JSON. ' \
                            'For an empty string, use --allow-empty alone.'
        end

        loaded = read_or_new(path)
        before_plain = decrypt(loaded)
        Store.check_writable!(path)

        base = before_plain.empty? ? { 'id' => ::File.basename(path, '.json') } : before_plain
        after_plain = base.merge(key => read_value)
        conflict = -> { raise Error, "#{path} changed on disk while eedbi was running. Nothing was written." }
        report_save(loaded, save(loaded, before_plain, after_plain, on_conflict: conflict), before_plain, after_plain)
        0
      end

      private

      def stdin_usage = 'eedbi set ITEM KEY < value.txt'

      def check_arguments!(arguments)
        return if arguments.size == 2

        raise UsageError, "eedbi set needs ITEM and KEY (#{received(arguments)})\n" \
                          "Run 'eedbi help set' for usage."
      end

      def define_options(opts)
        define_from_file_option(opts, 'Read the value from PATH, exactly (- for stdin)')
        opts.on('--json-value', 'Parse the value as JSON (a number, true, an object...)') do
          @options[:json_value] = true
        end
        opts.on('--allow-empty', 'Accept an empty value from stdin or a file') do
          @options[:allow_empty] = true
        end
        define_dry_run_option(opts)
        define_write_version_option(opts)
      end

      # From --from-file exactly; from stdin less one trailing newline; or,
      # when stdin is a terminal, typed. A terminal on stdin can only mean a
      # person about to type the value, and a hidden prompt is the safe way
      # to take it.
      def read_value
        text = if !reads_stdin? then checked(read_from_file(@options[:from_file]))
               elsif @context.stdin_tty then prompt_value
               else checked(stdin_text.delete_suffix("\n").delete_suffix("\r"))
               end
        @options[:json_value] ? Store.parse_json(text) : text
      rescue JSON::ParserError
        raise Error, "The value for #{Eedbi.quote_key(@key)} is not valid JSON"
      end

      # stdin as UTF-8, whatever the locale: under LANG=C, Ruby would label
      # it US-ASCII and every accented value would look invalid.
      def stdin_text
        stdin.read.to_s.dup.force_encoding(Encoding::UTF_8)
      end

      # A typed value is taken as typed: not stripped, and it may be empty,
      # since typing nothing twice is deliberate.
      def prompt_value
        console = @context.console.call or raise Error, 'Typing the value needs a terminal'
        value = console.getpass("Value for #{Eedbi.quote_key(@key)}: ").to_s.chomp
        repeated = console.getpass("Repeat value for #{Eedbi.quote_key(@key)}: ").to_s.chomp
        raise Error, "The values for #{Eedbi.quote_key(@key)} do not match" unless repeated == value

        value
      end

      # An empty input is far more often a mistake, such as an unset
      # variable or a script without stdin, than a value meant to be empty.
      def checked(value)
        unless value.valid_encoding?
          raise Error, "The value for #{Eedbi.quote_key(@key)} is not valid UTF-8; data bag values must be text"
        end

        if value.empty? && !@options[:allow_empty]
          hint = if @options[:json_value] then 'An empty value is not JSON; an empty string is "".'
                 else 'To set an empty string, pass --allow-empty.'
                 end
          raise Error, "The value for #{Eedbi.quote_key(@key)} from #{input_label} is empty. #{hint}"
        end

        value
      end
    end
  end
end
