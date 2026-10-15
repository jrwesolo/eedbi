# frozen_string_literal: true

module Eedbi
  module Commands
    # Decrypts an item, or one value, into the editor, then encrypts and saves
    # the result.
    class Edit < Base
      command summary: 'Edit an item in your editor, creating it if needed',
              arguments: 'ITEM [KEY]',
              description: <<~TEXT,
                Decrypts ITEM into a private temporary file, opens it in your
                editor and encrypts the result back into ITEM. Values you did
                not change keep their ciphertext, so diffs stay small.

                With KEY, only that value is edited. A string opens as plain
                text with real line breaks, which suits certificates and
                keys; other values open as JSON. --json-value opens a string,
                or a new key, as JSON too.

                Only the values that change are encrypted again, each in its
                own version unless --encrypt-version is given; 'eedbi migrate'
                converts whole items. Version 0 cannot be written, so changed
                version 0 values take the item's highest version.

                Refused when $EEDBI_NO_PLAINTEXT is set.
              TEXT
              examples: <<~TEXT
                eedbi edit data_bags/db/mysql.json
                eedbi edit data_bags/web/tls.json certificate
                eedbi edit data_bags/db/mysql.json replicas --json-value   # as JSON, not plain text
                eedbi edit data_bags/db/mysql.json --editor 'code --wait'
              TEXT

      def initialize(context)
        super
        @options[:editor] = Editor.default
      end

      def execute((path, key))
        @path = path
        @key = key
        raise UsageError, '--json-value needs KEY' if @options[:json_value] && !key
        raise UsageError, 'The id is not encrypted; edit the whole item to change it' if key == 'id'

        refuse_plaintext!("To change values without showing them, use 'eedbi set', 'eedbi unset' or 'eedbi write'.")
        unless @context.stdin_tty && @context.stdout_tty
          raise Error, "eedbi edit needs a terminal. To read JSON from stdin, use 'eedbi write ITEM < plain.json'."
        end

        loaded = read_or_new(path)
        before_plain = decrypt(loaded)
        check_before_editing!(loaded)

        base = before_plain.empty? ? { 'id' => ::File.basename(path, '.json') } : before_plain
        after_plain = catch(:discard) { key ? edit_value(base, key) : edit_item(base) }
        unless after_plain
          stderr.puts 'Changes discarded'
          return 1
        end

        result = save_edit(loaded, base, before_plain, after_plain)
        report_save(loaded, result, before_plain, after_plain)
        warn_background_editor if result == :unchanged
        0
      end

      private

      def define_options(opts)
        opts.on('-e', '--editor EDITOR',
                'Editor command. Default: $EEDBI_EDITOR, $VISUAL, $EDITOR,',
                "then #{Editor.platform_default} (currently: #{@options[:editor]})") do |editor|
          @options[:editor] = editor
        end
        opts.on('--json-value', 'With KEY, edit a string value, or a new key, as JSON') do
          @options[:json_value] = true
        end
        define_write_version_option(opts)
      end

      # What the editor showed, left as it was, changes nothing: not even a
      # new key left empty, or a new item's template, which would otherwise
      # create the file with only its id.
      def save_edit(loaded, base, before_plain, after_plain)
        return :unchanged if after_plain.eql?(base)

        save(loaded, before_plain, after_plain, on_conflict: -> { overwrite_changed_file?(loaded.path) })
      end

      # Everything that would stop the save, checked before the editor opens
      # so that no edit is wasted. Anything may change in the editor, so the
      # version check covers every value it shows.
      def check_before_editing!(loaded)
        Store.check_writable!(loaded.path)
        check_no_downgrade!(loaded, @key ? [@key] : loaded.item.keys - ['id'])
      end

      def edit_item(item)
        edit_text(Store.dump(item), "#{basename}.json", 'Invalid data bag item') do |text|
          Store.parse_json(text).tap { |content| Item.validate!(content) }
        end
      end

      # A new key opens empty, or as null with --json-value. Left that way,
      # the item is returned unchanged.
      def edit_value(item, key)
        value = item[key]
        file = "#{basename}.#{key.gsub(/[^\w.-]/, '_')[0, 40]}"
        if @options[:json_value] || (item.key?(key) && !value.is_a?(String))
          edited = edit_text("#{JSON.pretty_generate(value)}\n", "#{file}.json", 'Invalid value') do |text|
            Store.parse_json(text)
          end
          untouched = nil
        else
          edited = edit_text(value.to_s, "#{file}.txt", 'Invalid value') { |text| raw_value(value, text) }
          untouched = ''
        end
        !item.key?(key) && edited == untouched ? item : item.merge(key => edited)
      end

      # Editors usually end a saved file with a newline. Keep the original's
      # choice: a password stays without one, a certificate keeps its own.
      def raw_value(original, text)
        raise Error, 'The value is not valid UTF-8' unless text.valid_encoding?
        return text if original.is_a?(String) && original.end_with?("\n")

        text.delete_suffix("\n")
      end

      def basename
        ::File.basename(@path, '.json')
      end

      # Someone else may have changed the item while it was open in the
      # editor, for example with git pull or a second eedbi. Overwriting it
      # would silently undo that change, so ask first.
      def overwrite_changed_file?(path)
        stderr.puts "Warning: #{path} changed on disk while it was open in the editor."
        ask_yes_no('Overwrite it with your changes? Answering N discards your changes [y/N]? ', default: false)
      end

      # Writes `content` to a file in a private (0700) directory, preferably
      # on a RAM backed filesystem, and opens it in the editor until the block
      # accepts the result. The directory is removed when editing ends,
      # including on Ctrl-C or SIGTERM. An external editor needs a real path,
      # so this cannot be done purely in memory. Throws :discard when the
      # user gives up, since nil is a valid result (JSON null).
      def edit_text(content, filename, invalid_label)
        Dir.mktmpdir('eedbi', private_tmp_base) do |dir|
          path = ::File.join(dir, filename)
          ::File.open(path, ::File::WRONLY | ::File::CREAT | ::File::EXCL, 0o600) { |file| file.write(content) }

          loop do
            run_editor(path)
            begin
              return yield ::File.read(path, encoding: Encoding::UTF_8)
            rescue JSON::ParserError => e
              stderr.puts e.message.lines.first.strip
              throw :discard unless ask_yes_no('Unable to parse JSON. Edit again [Y/N]? ')
            rescue Error => e
              stderr.puts e.message
              throw :discard unless ask_yes_no("#{invalid_label}. Edit again [Y/N]? ")
            end
          end
        end
      end

      def private_tmp_base
        [ENV.fetch('XDG_RUNTIME_DIR', nil), '/dev/shm'].compact.find do |dir|
          ::File.directory?(dir) && ::File.writable?(dir)
        end || Dir.tmpdir
      end

      def run_editor(path)
        command = Editor.command(@options[:editor])
        raise Error, 'No editor configured (set $EDITOR or use --editor)' if command.empty?

        # A Ctrl-C meant for the editor must not kill eedbi and delete the
        # file out from under it. A handler block (unlike 'IGNORE') is not
        # inherited by the editor process.
        previous = trap('INT') { nil }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          status = system(*command, path)
        ensure
          trap('INT', previous)
        end
        @editor_seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        return if status

        raise Error, "Editor #{editor_failure(status)}: #{@options[:editor]}\nChanges discarded"
      end

      def editor_failure(status)
        last = Process.last_status
        if status.nil? then 'could not be started'
        elsif last.signaled? then "was killed by signal #{last.termsig}"
        else "exited with #{last.exitstatus}"
        end
      end

      # GUI editors often return immediately unless told to wait, which looks
      # exactly like closing the editor without changes.
      def warn_background_editor
        return unless @editor_seconds && @editor_seconds < 1

        stderr.puts "Hint: the editor returned after #{@editor_seconds.round(2)}s. If it runs in the background, " \
                    "make it wait, for example: --editor 'code --wait'"
      end

      # `default` is the answer for an empty line; without one, ask again.
      def ask_yes_no(prompt, default: nil)
        loop do
          stderr.print prompt
          answer = stdin.gets
          if answer.nil? # EOF (Ctrl-D)
            stderr.puts
            return false
          end

          return default if answer.strip.empty? && !default.nil?

          case answer.strip.downcase
          when 'y', 'yes' then return true
          when 'n', 'no' then return false
          end
        end
      end
    end
  end
end
