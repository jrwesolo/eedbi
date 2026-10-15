# frozen_string_literal: true

module Eedbi
  # Reading and writing item files, and parsing JSON input.
  module Store
    # An item as read from disk. `bytes` is the exact file content, or nil
    # when the file does not exist, so that a later write can tell whether
    # someone else changed the file in the meantime.
    Loaded = Struct.new(:path, :item, :bytes) do
      def exist?
        !bytes.nil?
      end

      def changed_on_disk?
        (::File.exist?(path) ? ::File.binread(path) : nil) != bytes
      end
    end

    module_function

    def read(path)
      check_not_dangling!(path)
      return Loaded.new(path, {}, nil) unless ::File.exist?(path)

      check_not_directory!(path)
      bytes = ::File.binread(path)
      item = parse_json(bytes, unique_keys: false, not_utf8: "#{path}: not valid UTF-8, which JSON requires")
      raise Error, "#{path}: data bag item must be a JSON object" unless item.is_a?(Hash)

      Loaded.new(path, item, bytes)
    rescue JSON::ParserError
      raise Error, "#{path}: unable to parse JSON"
    end

    # Each path once, as first given, even when overlapping globs or a
    # symlink name a file twice. Otherwise migrate and rekey would write it
    # twice, and stop halfway on the second, finding it changed on disk.
    def distinct(paths)
      paths.uniq do |path|
        # - is stdin, not a file named -, which ./- would still reach.
        next path if path == '-'

        ::File.exist?(path) ? ::File.realpath(path) : ::File.expand_path(path)
      end
    end

    # Without this, reading a directory fails with a bare "Is a directory @
    # io_fread" from Ruby.
    def check_not_directory!(path)
      return unless ::File.directory?(path)

      raise Error, "#{path} is a directory; pass the items in it, for example #{::File.join(path, '*.json')}"
    end

    # A symlink whose target is missing usually means the target moved.
    # Writing would replace the link with a new item in the old place, as
    # GNU cp refuses to do.
    def check_not_dangling!(path)
      return if ::File.exist?(path) || !::File.symlink?(path)

      raise Error, "#{path} is a symlink to a missing file (#{::File.readlink(path)})"
    end

    # An item piped in, as from `git show main:item.json | eedbi read -`.
    def read_stream(stream)
      bytes = stream.read.to_s.b
      raise Error, 'stdin is empty (expected the item as JSON)' if bytes.strip.empty?

      item = parse_json(bytes, unique_keys: false, not_utf8: 'Data bag item from stdin is not valid UTF-8')
      raise Error, 'Data bag item from stdin must be a JSON object' unless item.is_a?(Hash)

      Loaded.new('-', item, bytes)
    rescue JSON::ParserError
      raise Error, 'Unable to parse JSON from stdin'
    end

    # Some editors, such as older versions of Notepad, start UTF-8 files with
    # a byte order mark, which JSON does not allow.
    #
    # Repeated keys are rejected in the user's input, but tolerated in an item
    # read from disk so that existing items keep loading.
    #
    # json 2.13 and later check repeated keys themselves (allow_duplicate_key)
    # and never reach UniqueKeyHash#[]= for them; older versions ignore that
    # option, and UniqueKeyHash catches them instead.
    #
    # // and /* */ comments are accepted, as Chef does (json 3 needs
    # allow_comments for that; json 2 accepts them anyway), and, as with
    # knife, not kept when the item is written.
    #
    # Invalid UTF-8 is refused with `not_utf8` as the message. json 2 lets
    # it into strings, where it would fail much later, in a regex match or
    # when the item is written.
    def parse_json(text, unique_keys: true, not_utf8: 'The JSON is not valid UTF-8')
      text = text.b.delete_prefix("\xEF\xBB\xBF".b).force_encoding(Encoding::UTF_8)
      raise Error, not_utf8 unless text.valid_encoding?

      options = { allow_duplicate_key: !unique_keys, allow_comments: true }
      options[:object_class] = UniqueKeyHash if unique_keys
      check_finite!(JSON.parse(text, **options))
    rescue JSON::ParserError => e
      raise unless unique_keys && e.message.start_with?('duplicate key')

      raise DuplicateKeyError, e.message.sub('duplicate key', 'Duplicate key')
    end

    # A number too large for a float, such as 1e400, is read as Infinity,
    # which JSON cannot write, so saving the item would fail later.
    def check_finite!(value)
      case value
      when Float then raise Error, 'The JSON has a number too large to keep (it reads as Infinity)' unless value.finite?
      when Array then value.each { |element| check_finite!(element) }
      when Hash then value.each_value { |element| check_finite!(element) }
      end
      value
    end

    def dump(item)
      "#{JSON.pretty_generate(item)}\n"
    end

    # Write to a temporary file in the same directory, then rename it over the
    # original so an interrupted write never leaves a truncated item behind.
    #
    # BINARY keeps LF line endings on Windows, where text mode writes CRLF.
    def write_atomic(path, content)
      target = write_target(path)
      mode = ::File.exist?(target) ? ::File.stat(target).mode & 0o7777 : 0o666 & ~::File.umask
      name = ".#{::File.basename(target)}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
      tmp_path = ::File.join(::File.dirname(target), name)
      tmp = nil
      ::File.open(tmp_path, ::File::WRONLY | ::File::CREAT | ::File::EXCL | ::File::BINARY, 0o600) do |file|
        tmp = tmp_path
        file.write(content)
        file.flush
        file.fsync
      end
      ::File.chmod(mode, tmp)
      ::File.rename(tmp, target)
    ensure
      # Only ever remove a file this method created.
      ::File.unlink(tmp) if tmp && ::File.exist?(tmp)
    end

    # The file that will be replaced: the target of a symlink, so the link
    # itself is preserved.
    def write_target(path)
      ::File.exist?(path) ? ::File.realpath(path) : ::File.expand_path(path)
    end

    # Fails before any work when the item could not be saved afterwards, so
    # that edits are never lost to, for example, a missing data bag directory
    # or a read-only checkout.
    def check_writable!(path)
      dir = ::File.dirname(write_target(path))
      raise Error, "Directory not found: #{dir}" unless ::File.directory?(dir)
      raise Error, "Directory not writable: #{dir}" unless ::File.writable?(dir)
    end
  end
end
