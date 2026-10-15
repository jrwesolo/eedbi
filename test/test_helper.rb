# frozen_string_literal: true

# Shared helpers. Tests are in four layers:
#
#   test/unit    single modules, in-process
#   test/cli     whole commands through Eedbi.main with injected streams
#   test/system  bin/eedbi as a real subprocess, under a PTY where a terminal
#                is needed (skipped on Windows), and real vim and neovim
#   test/compat  against Chef's own implementation (skipped without Chef)
#
# Only test/compat needs Chef. Everything else runs on every platform with
# the standard library.

require 'minitest/autorun'
require 'fileutils'
require 'json'
require 'rbconfig'
require 'stringio'
require 'tmpdir'
require_relative '../lib/eedbi'

# The developer's own settings must not change the results. Tests that need
# one set it with with_env.
%w[ENCRYPTED_DATA_BAG_SECRET EEDBI_DEFAULT_ENCRYPT_VERSION EEDBI_DECRYPT_MINIMUM_VERSION
   EEDBI_NO_PLAINTEXT].each { |var| ENV.delete(var) }

module EedbiTestHelper
  ROOT = File.expand_path('..', __dir__)
  FIXTURES = File.join(ROOT, 'test', 'fixtures')
  WINDOWS = Gem.win_platform?

  Result = Struct.new(:out, :err, :status)

  # Answers prompts in place of IO.console. With one answer, every prompt
  # gets it (so a confirmation matches); with several, they are used in turn.
  class FakeConsole
    attr_reader :prompts

    def initialize(*answers)
      @answers = answers
      @prompts = []
    end

    def getpass(prompt)
      @prompts << prompt
      @answers.size > 1 ? @answers.shift : @answers.first
    end
  end

  # Each test works on copies of the fixtures in a fresh directory.
  def setup
    @dir = Dir.mktmpdir('eedbi-test')
    FileUtils.cp(Dir.glob(File.join(FIXTURES, '*')).reject { |file| file.end_with?('.rb', '.md') }, @dir)
    # Git checks files out world-readable, which eedbi warns about.
    %w[encrypted_data_bag_secret other_secret].each { |name| File.chmod(0o600, path(name)) }
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def path(*parts)
    File.join(@dir, *parts)
  end

  # A line that a command on one item prints about it.
  def report(name, text)
    "#{path(name)}: #{text}\n"
  end

  def secret(name = 'encrypted_data_bag_secret')
    File.read(path(name)).strip
  end

  # Runs eedbi in-process. Unless `secret: false`, the fixture secret is
  # passed with -s. `interactive: true` takes the terminal paths (edit,
  # prompts) even though no terminal is attached; prompts read from `stdin`.
  # `stdout` replaces the StringIO that collects the output.
  def eedbi(*args, stdin: '', interactive: true, secret: true, console: nil, stdout: nil)
    out = stdout || StringIO.new
    err = StringIO.new
    args += ['-s', path('encrypted_data_bag_secret')] if secret
    status = Eedbi.main(args, stdin: StringIO.new(stdin), stdout: out, stderr: err,
                              interactive: interactive, console: console)
    Result.new(out.string, err.string, status)
  end

  # An stdout that changes the file at `path` on disk when the first line
  # is printed, as someone else could while migrate or rekey writes items.
  def stdout_changing(path)
    out = StringIO.new
    out.define_singleton_method(:puts) do |*lines|
      File.write(path, "#{File.read(path)} ") if string.empty?
      super(*lines)
    end
    out
  end

  # An stdout piped to a reader that has stopped, as `| head -1` does.
  def stdout_closed
    out = StringIO.new
    out.define_singleton_method(:puts) { |*| raise Errno::EPIPE }
    out.define_singleton_method(:print) { |*| raise Errno::EPIPE }
    out
  end

  # Runs eedbi with the working directory set to the test directory.
  def eedbi_in_dir(*args, **options)
    Dir.chdir(@dir) { eedbi(*args, **options) }
  end

  def with_env(vars)
    previous = vars.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    vars.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end

  def read_json(name)
    JSON.parse(File.read(path(name)))
  end

  def decrypt(name, key = secret)
    Eedbi::Item.decrypt(read_json(name), key)
  end

  # plain.json under the id of the given fixture.
  def plain(id)
    JSON.parse(File.read(File.join(FIXTURES, 'plain.json'))).merge('id' => id)
  end

  def versions(name)
    read_json(name).except('id').values.map { |field| Eedbi::Crypto.version_of(field) }.uniq.sort
  end

  def write_editor_script(body, dir, name)
    FileUtils.mkdir_p(dir)
    script = File.join(dir, "#{name}.rb")
    File.write(script, "require 'json'\npath = ARGV.last\n#{body}\n")
    script
  end

  # An editor setting that runs `body` (Ruby, with `path` set to the file
  # being edited) through the current Ruby. Both paths are double quoted,
  # which both the POSIX and the Windows splitting accept.
  def ruby_editor(body, dir: @dir, name: 'editor')
    %("#{RbConfig.ruby}" "#{write_editor_script(body, dir, name)}")
  end

  # A standalone executable editor: a .cmd wrapper on Windows, a script with
  # a shebang elsewhere. Returns its path.
  def executable_editor(body, dir: @dir, name: 'editor')
    script = write_editor_script(body, dir, name)
    if WINDOWS
      exe = File.join(dir, "#{name}.cmd")
      File.write(exe, %(@"#{RbConfig.ruby.tr('/', '\\')}" "#{script.tr('/', '\\')}" %*\n))
    else
      exe = File.join(dir, name)
      File.write(exe, "#!#{RbConfig.ruby}\n#{File.read(script)}")
      File.chmod(0o755, exe)
    end
    exe
  end
end
