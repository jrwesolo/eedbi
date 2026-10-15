# frozen_string_literal: true

require_relative '../test_helper'
require 'open3'
require 'shellwords'

begin
  require 'pty'
rescue LoadError
  # Windows has no PTY. Tests that need one skip themselves there; test/cli
  # covers the same flows in-process.
end

# bin/eedbi as a real subprocess: terminal detection, signals, and running
# without RubyGems. Only what the in-process tests in test/cli cannot cover.
class TerminalTest < Minitest::Test
  include EedbiTestHelper

  EEDBI = File.join(ROOT, 'bin', 'eedbi')

  # Isolated from the user's environment: no ~/.chef, no secret variable,
  # no editor settings.
  def env(extra = {})
    { 'HOME' => @dir, 'ENCRYPTED_DATA_BAG_SECRET' => nil, 'EDITOR' => nil, 'VISUAL' => nil,
      'EEDBI_EDITOR' => nil, 'EEDBI_DEFAULT_ENCRYPT_VERSION' => nil, 'EEDBI_NO_PLAINTEXT' => nil }.merge(extra)
  end

  def run_eedbi(*args, stdin: '', ruby_opts: [])
    out, err, status = Open3.capture3(env, RbConfig.ruby, *ruby_opts, EEDBI, *args, stdin_data: stdin, chdir: @dir)
    Result.new(out, err, status)
  end

  # Runs eedbi under a PTY, so stdin and stdout are a terminal. Output is
  # stdout and stderr combined. The block is called as (writer, pid, output)
  # on every poll.
  def run_eedbi_pty(*args, extra_env: {}, timeout: 30, &)
    run_pty(env(extra_env), RbConfig.ruby, EEDBI, *args, timeout: timeout, &)
  end

  def run_pty(*command, timeout: 30)
    skip 'needs a PTY, which Windows does not have' unless defined?(PTY)

    output = +''
    reader, writer, pid = PTY.spawn(*command, chdir: @dir)
    deadline = Time.now + timeout
    loop do
      raise "eedbi timed out, output so far:\n#{output}" if Time.now > deadline

      yield writer, pid, output if block_given?
      next unless reader.wait_readable(0.1)

      begin
        output << reader.readpartial(4096)
      rescue EOFError, Errno::EIO
        break
      end
    end
    _, status = Process.wait2(pid)
    Result.new(output.gsub("\r\n", "\n"), '', status)
  end

  def test_edit_in_a_terminal
    editor = executable_editor("data = JSON.parse(File.read(path)); data['password'] = 'edited'; " \
                               'File.write(path, JSON.generate(data))')
    r = run_eedbi_pty('edit', 'v3.json', '-e', editor)
    assert r.status.success?, r.out
    assert_match(/v3\.json: changed "password"/, r.out)
    assert_equal 'edited', decrypt('v3.json')['password']
  end

  def test_edit_refuses_when_stdout_is_not_a_terminal
    r = run_eedbi('edit', 'v3.json', '-e', executable_editor('nil'))
    refute r.status.success?
    assert_match(/eedbi edit needs a terminal/, r.err)
  end

  def test_write_refuses_a_terminal_on_stdin
    r = run_eedbi_pty('write', 'new.json')
    refute r.status.success?
    assert_match(/reads the item from stdin, but stdin is a terminal/, r.out)
  end

  def test_write_from_a_pipe
    r = run_eedbi('write', 'new.json', stdin: '{"id":"new","a":1}')
    assert r.status.success?, r.err
    assert_equal({ 'id' => 'new', 'a' => 1 }, decrypt('new.json'))
  end

  def test_runs_without_rubygems
    r = run_eedbi('read', 'v3.json', ruby_opts: ['--disable-gems'])
    assert r.status.success?, r.err
    assert_equal plain('v3'), JSON.parse(r.out)
  end

  def test_secret_prompt_does_not_echo
    skip 'needs a PTY, which Windows does not have' unless defined?(PTY)

    r = nil
    Dir.chdir(@dir) do
      FileUtils.mv('encrypted_data_bag_secret', 'kept_secret')
      typed = false
      r = run_eedbi_pty('read', 'v3.json', 'password', '--secret-prompt') do |writer, _pid, output|
        # Typed ahead of the prompt, the terminal would still echo it.
        next if typed || !output.include?(Eedbi::Secret::PROMPT)

        writer.write("#{File.read('kept_secret').strip}\n")
        typed = true
      end
    end
    assert r.status.success?, r.out
    assert_match(/hunter2/, r.out)
    refute_includes r.out, secret('kept_secret'), 'the secret was echoed'
  end

  # The secret comes from the terminal while the item comes from stdin.
  def test_secret_prompt_with_piped_stdin
    skip 'needs a PTY, which Windows does not have' unless defined?(PTY)

    FileUtils.mv(path('encrypted_data_bag_secret'), path('kept_secret'))
    command = "#{RbConfig.ruby.shellescape} #{EEDBI.shellescape} write new.json --secret-prompt < plain.json"
    typed = false
    r = run_pty(env, 'sh', '-c', command) do |writer, _pid, output|
      next if typed || !output.include?(Eedbi::Secret::PROMPT)

      writer.write("#{secret('kept_secret')}\n")
      typed = true
    end
    assert r.status.success?, r.out
    assert_equal plain('new'), decrypt('new.json', secret('kept_secret'))
  end

  def test_ctrl_c_in_editor_does_not_abort
    skip 'needs a PTY, which Windows does not have' unless defined?(PTY)

    ready = path('ready')
    editor = executable_editor(<<~RUBY)
      trap('INT') {}
      File.write(#{ready.inspect}, '')
      sleep 1
      File.write(path, '{"id":"v3","after":"ctrl-c"}')
    RUBY
    sent = false
    r = run_eedbi_pty('edit', 'v3.json', '-e', editor) do |writer, _pid|
      if !sent && File.exist?(ready)
        writer.write("\x03")
        sent = true
      end
    end
    assert sent
    assert r.status.success?, r.out
    assert_equal({ 'id' => 'v3', 'after' => 'ctrl-c' }, decrypt('v3.json'))
  end

  def test_sigterm_during_edit_removes_plaintext
    skip 'needs a PTY and POSIX signals' unless defined?(PTY)

    log = path('editor.json')
    editor = executable_editor(<<~RUBY)
      File.write(#{log.inspect}, JSON.generate('path' => path, 'pid' => Process.pid))
      sleep 10
    RUBY
    sent = false
    before = File.read(path('v3.json'))
    run_eedbi_pty('edit', 'v3.json', '-e', editor) do |_writer, pid|
      if !sent && File.exist?(log) && !File.empty?(log)
        Process.kill('TERM', pid)
        sent = true
      end
    end
    info = JSON.parse(File.read(log))
    begin
      Process.kill('KILL', info['pid'])
    rescue Errno::ESRCH
      nil
    end
    refute File.exist?(File.dirname(info['path'])), 'private temp dir left behind'
    assert_equal before, File.read(path('v3.json'))
  end

  # The documented git integration: `git diff` shows decrypted items.
  def test_git_textconv
    skip 'git not installed' unless system('git', '--version', out: File::NULL, err: File::NULL)

    git = ->(*args) { system('git', '-c', 'user.name=t', '-c', 'user.email=t@example.com', *args, chdir: @dir) }
    File.write(path('.gitattributes'), "*.json diff=eedbi\n")
    assert git.call('init', '-q')
    assert git.call('add', 'v3.json', '.gitattributes')
    assert git.call('commit', '-q', '-m', 'initial')
    run_eedbi('write', 'v3.json', stdin: JSON.generate(plain('v3').merge('password' => 'changed')))

    textconv = "#{RbConfig.ruby} #{EEDBI} read"
    diff, = Open3.capture2(env, 'git', '-c', "diff.eedbi.textconv=#{textconv}", 'diff', 'v3.json', chdir: @dir)
    assert_match(/^-  "password": "hunter2",\r?$/, diff)
    assert_match(/^\+  "password": "changed",\r?$/, diff)

    # With --digest, the changed value shows as a changed digest, and the
    # plaintext not at all.
    diff, = Open3.capture2(env, 'git', '-c', "diff.eedbi.textconv=#{textconv} --digest", 'diff', 'v3.json', chdir: @dir)
    assert_match(/^-  "password": "hmac:\h{16}",\r?$/, diff)
    assert_match(/^\+  "password": "hmac:\h{16}",\r?$/, diff)
    assert_equal 2, diff.lines.grep(/^[-+] /).size, 'only the changed value'
    refute_match(/hunter2|changed/, diff)
  end
end
