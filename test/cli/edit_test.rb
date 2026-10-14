# frozen_string_literal: true

require_relative '../test_helper'

# The interactive editor flow, driven in-process with terminal detection
# overridden. A real editor process is started on every platform; only the
# terminal itself is simulated. Prompts are answered through stdin.
class EditTest < Minitest::Test
  include EedbiTestHelper

  EDIT_PASSWORD = <<~RUBY
    data = JSON.parse(File.read(path))
    data['password'] = 'edited'
    File.write(path, JSON.generate(data))
  RUBY

  def test_edit_is_saved
    r = eedbi('edit', path('v3.json'), '-e', ruby_editor(EDIT_PASSWORD))
    assert_equal 0, r.status, r.err
    assert_equal report('v3.json', 'changed "password"'), r.out
    assert_equal 'edited', decrypt('v3.json')['password']
  end

  def test_new_item_template_uses_basename_as_id
    seen = path('seen.json')
    r = eedbi('edit', path('brand_new.json'), '-e', ruby_editor("File.write(#{seen.inspect}, File.read(path))"))
    assert_equal 0, r.status, r.err
    assert_equal({ 'id' => 'brand_new' }, JSON.parse(File.read(seen)))
  end

  def test_no_change
    before = File.read(path('v3.json'))
    r = eedbi('edit', path('v3.json'), '-e', ruby_editor('nil'))
    assert_equal 0, r.status, r.err
    assert_match(/v3\.json: no changes/, r.out)
    assert_equal before, File.read(path('v3.json'))
  end

  def test_crlf_line_endings_are_accepted
    editor = ruby_editor(%(File.binwrite(path, "{\\r\\n  \\"id\\": \\"v3\\",\\r\\n  \\"crlf\\": true\\r\\n}\\r\\n")))
    r = eedbi('edit', path('v3.json'), '-e', editor)
    assert_equal 0, r.status, r.err
    assert_equal({ 'id' => 'v3', 'crlf' => true }, decrypt('v3.json'))
  end

  def test_invalid_json_then_retry
    counter = path('count')
    editor = ruby_editor(<<~RUBY)
      n = File.exist?(#{counter.inspect}) ? File.read(#{counter.inspect}).to_i : 0
      File.write(#{counter.inspect}, (n + 1).to_s)
      File.write(path, n.zero? ? '{ broken' : '{"id":"v3","fixed":true}')
    RUBY
    r = eedbi('edit', path('v3.json'), '-e', editor, stdin: "y\n")
    assert_equal 0, r.status, r.err
    assert_match(/Unable to parse JSON. Edit again/, r.err)
    assert_equal({ 'id' => 'v3', 'fixed' => true }, decrypt('v3.json'))
  end

  def test_invalid_json_then_decline
    before = File.read(path('v3.json'))
    r = eedbi('edit', path('v3.json'), '-e', ruby_editor("File.write(path, '{ broken')"), stdin: "n\n")
    assert_equal 1, r.status
    assert_match(/Changes discarded/, r.err)
    assert_equal before, File.read(path('v3.json'))
  end

  def test_eof_at_prompt_discards
    r = eedbi('edit', path('v3.json'), '-e', ruby_editor("File.write(path, '{ broken')"), stdin: '')
    assert_equal 1, r.status
    assert_match(/Changes discarded/, r.err)
  end

  def test_invalid_id_reprompts
    r = eedbi('edit', path('v3.json'), '-e', ruby_editor(%(File.write(path, '{"id":"bad id"}'))), stdin: "n\n")
    assert_equal 1, r.status
    assert_match(/Invalid data bag item. Edit again/, r.err)
  end

  def test_failing_editor_discards
    r = eedbi('edit', path('v3.json'), '-e', ruby_editor('exit 3'))
    assert_equal 1, r.status
    assert_match(/v3\.json: editor exited with 3/, r.err)
  end

  def test_missing_editor_fails
    r = eedbi('edit', path('v3.json'), '-e', path('no_such_editor'))
    assert_equal 1, r.status
    assert_match(/v3\.json: editor could not be started/, r.err)
  end

  def test_temp_file_is_private_and_removed
    log = path('log.json')
    editor = ruby_editor(<<~RUBY)
      File.write(#{log.inspect}, JSON.generate('path' => path,
        'file_mode' => File.stat(path).mode & 0o777,
        'dir_mode' => File.stat(File.dirname(path)).mode & 0o777))
    RUBY
    eedbi('edit', path('v3.json'), '-e', editor)
    info = JSON.parse(File.read(log))
    assert_equal 'v3.json', File.basename(info['path'])
    refute File.exist?(File.dirname(info['path'])), 'private temp dir left behind'
    return if WINDOWS # POSIX modes do not apply

    assert_equal 0o600, info['file_mode']
    assert_equal 0o700, info['dir_mode']
  end

  # Unquoted path containing spaces. On Windows this is a .cmd wrapper, so it
  # also covers batch file editors.
  def test_unquoted_executable_path_with_spaces
    editor = executable_editor(EDIT_PASSWORD, dir: path('my editors'))
    r = eedbi('edit', path('v3.json'), '-e', editor)
    assert_equal 0, r.status, r.err
    assert_equal 'edited', decrypt('v3.json')['password']
  end

  def test_quoted_executable_path_with_spaces_and_arguments
    editor = executable_editor(EDIT_PASSWORD, dir: path('my editors'))
    r = eedbi('edit', path('v3.json'), '-e', %("#{editor}" --wait))
    assert_equal 0, r.status, r.err
    assert_equal 'edited', decrypt('v3.json')['password']
  end

  def test_save_replaces_existing_file
    eedbi('edit', path('v3.json'), '-e', ruby_editor(EDIT_PASSWORD))
    assert_empty Dir.glob(path('.v3.json.*')), 'temporary write file left behind'
    assert_equal 'edited', decrypt('v3.json')['password']
  end

  # The editor must not open when the result could not be saved, or the
  # edits would be lost.
  def test_missing_directory_fails_before_editing
    marker = path('editor_ran')
    r = eedbi('edit', path('no_such_bag', 'item.json'), '-e', ruby_editor("File.write(#{marker.inspect}, '')"))
    assert_equal 1, r.status
    assert_match(/v3\.json: directory not found: |item\.json: directory not found: /, r.err)
    refute File.exist?(marker), 'editor was started'
  end

  def test_read_only_directory_fails_before_editing
    skip 'POSIX permissions only' if WINDOWS
    skip 'root can write anywhere' if Process.uid.zero?

    FileUtils.mkdir(path('ro'))
    FileUtils.cp(path('v3.json'), path('ro', 'v3.json'))
    File.chmod(0o555, path('ro'))
    marker = path('editor_ran')
    r = eedbi('edit', path('ro', 'v3.json'), '-e', ruby_editor("File.write(#{marker.inspect}, '')"))
    assert_equal 1, r.status
    assert_match(/v3\.json: directory not writable: /, r.err)
    refute File.exist?(marker), 'editor was started'
  ensure
    File.chmod(0o755, path('ro')) if File.directory?(path('ro'))
  end

  def test_editor_killed_by_signal_discards
    skip 'no POSIX signals' if WINDOWS

    r = eedbi('edit', path('v3.json'), '-e', ruby_editor('Process.kill(:KILL, Process.pid)'))
    assert_equal 1, r.status
    assert_match(/v3\.json: editor was killed by signal 9/, r.err)
  end

  def test_byte_order_mark_is_accepted
    editor = ruby_editor(%(File.binwrite(path, "\\xEF\\xBB\\xBF" + '{"id":"v3","bom":1}')))
    r = eedbi('edit', path('v3.json'), '-e', editor)
    assert_equal 0, r.status, r.err
    assert_equal({ 'id' => 'v3', 'bom' => 1 }, decrypt('v3.json'))
  end

  def test_duplicate_key_in_editor_reprompts
    r = eedbi('edit', path('v3.json'), '-e', ruby_editor(%(File.write(path, '{"id":"v3","a":1,"a":2}'))), stdin: "n\n")
    assert_equal 1, r.status
    assert_match(/Duplicate key "a"/, r.err)
    assert_match(/Invalid data bag item. Edit again/, r.err)
  end

  # An editor that also changes the item on disk, as a git pull or a second
  # eedbi would while the editor is open.
  def conflicting_editor
    ruby_editor(<<~RUBY)
      #{EDIT_PASSWORD}
      File.write(#{path('v3.json').inspect}, File.read(#{path('v3.json').inspect}) + ' ')
    RUBY
  end

  def test_changed_on_disk_while_editing_overwrites_on_yes
    r = eedbi('edit', path('v3.json'), '-e', conflicting_editor, stdin: "y\n")
    assert_equal 0, r.status, r.err
    assert_match(/changed on disk while it was open in the editor/, r.err)
    assert_match(%r{Answering N discards your changes \[y/N\]}, r.err)
    assert_equal 'edited', decrypt('v3.json')['password']
  end

  def test_changed_on_disk_while_editing_discards_on_no_or_enter
    ["n\n", "\n", ''].each do |answer|
      FileUtils.cp(File.join(FIXTURES, 'v3.json'), path('v3.json'))
      r = eedbi('edit', path('v3.json'), '-e', conflicting_editor, stdin: answer)
      assert_equal 1, r.status, "answer #{answer.inspect}"
      assert_match(/v3\.json: changes discarded; the file was left as it is on disk/, r.err)
      assert_equal "#{File.read(File.join(FIXTURES, 'v3.json'))} ", File.read(path('v3.json')),
                   'the change made on disk must be kept'
    end
  end

  def test_refuses_without_a_terminal
    r = eedbi('edit', path('v3.json'), '-e', ruby_editor(EDIT_PASSWORD), interactive: false)
    assert_equal 1, r.status
    assert_match(/eedbi edit needs a terminal\. To read JSON from stdin, use 'eedbi write/, r.err)
  end

  def test_no_plaintext_refuses_before_decrypting
    opened = path('opened')
    with_env('EEDBI_NO_PLAINTEXT' => '0') do
      r = eedbi('edit', path('v3.json'), '-e', ruby_editor("File.write(#{opened.inspect}, '')"))
      assert_equal 1, r.status
      assert_match(/eedbi edit shows plaintext, which \$EEDBI_NO_PLAINTEXT disables\. .*'eedbi set'/, r.err)
    end
    refute File.exist?(opened), 'any value turns it on'
  end

  def test_editor_receives_the_decrypted_item
    seen = path('seen.json')
    eedbi('edit', path('v3.json'), '-e', ruby_editor("File.write(#{seen.inspect}, File.read(path))"))
    assert_equal plain('v3'), JSON.parse(File.read(seen))
  end

  # Each editor tags the item with its own name.
  def tagging_editor(name)
    ruby_editor("File.write(path, JSON.generate('id' => 'v3', 'by' => #{name.inspect}))", name: name)
  end

  def edited_by(env)
    with_env(env) { eedbi('edit', path('v3.json')) }
    decrypt('v3.json')['by']
  end

  def test_editor_precedence
    editors = { 'EEDBI_EDITOR' => tagging_editor('a'), 'VISUAL' => tagging_editor('b'),
                'EDITOR' => tagging_editor('c') }
    assert_equal 'a', edited_by(editors)
    assert_equal 'b', edited_by(editors.merge('EEDBI_EDITOR' => nil))
    assert_equal 'c', edited_by(editors.merge('EEDBI_EDITOR' => ' ', 'VISUAL' => ''))
  end

  def test_editor_option_beats_environment
    with_env('EEDBI_EDITOR' => tagging_editor('env')) do
      eedbi('edit', path('v3.json'), '-e', tagging_editor('flag'))
    end
    assert_equal 'flag', decrypt('v3.json')['by']
  end

  def test_vim_is_hardened_before_user_arguments
    log = path('argv.json')
    vim = executable_editor("File.write(#{log.inspect}, JSON.generate(ARGV))", dir: path('bin'), name: 'vim')
    eedbi('edit', path('v3.json'), '-e', %("#{vim}" -O))
    argv = JSON.parse(File.read(log))
    assert_equal [*Eedbi::Editor::VIM_HARDENING, '-O'], argv[0..-2]
    assert_equal 'v3.json', File.basename(argv.last)
  end

  def test_other_editors_get_no_extra_arguments
    log = path('argv.json')
    nano = executable_editor("File.write(#{log.inspect}, JSON.generate(ARGV))", dir: path('bin'), name: 'nano')
    eedbi('edit', path('v3.json'), '-e', nano)
    assert_equal 1, JSON.parse(File.read(log)).size
  end

  def test_instant_return_without_changes_hints_at_background_editor
    r = eedbi('edit', path('v3.json'), '-e', ruby_editor('nil'))
    assert_match(/v3\.json: no changes/, r.out)
    assert_match(/--editor 'code --wait'/, r.err)
  end

  def test_slow_editor_without_changes_gets_no_hint
    r = eedbi('edit', path('v3.json'), '-e', ruby_editor('sleep 1.2'))
    assert_match(/v3\.json: no changes/, r.out)
    refute_match(/Hint:/, r.err)
  end

  def test_prompt_asks_again_on_unrecognized_answer
    r = eedbi('edit', path('v3.json'), '-e', ruby_editor("File.write(path, '{ broken')"), stdin: "maybe\nn\n")
    assert_equal 1, r.status
    assert_equal 2, r.err.scan('Edit again [Y/N]? ').size
  end

  # Writes what the editor saw to `seen`, then replaces it with `content`.
  def replacing_editor(content, seen: path('seen'))
    ruby_editor("File.binwrite(#{seen.inspect}, File.binread(path)); File.binwrite(path, #{content.inspect})")
  end

  def test_key_opens_a_string_as_plain_text
    r = eedbi('edit', path('v3.json'), 'password', '-e', replacing_editor("changed\n"))
    assert_equal 0, r.status, r.err
    assert_equal 'hunter2', File.binread(path('seen'))
    assert_equal 'changed', decrypt('v3.json')['password'], 'the trailing newline the editor adds is dropped'
  end

  def test_key_keeps_a_trailing_newline_the_value_had
    pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
    eedbi('set', path('v3.json'), 'cert', '--from-file', '-', stdin: pem, interactive: false)
    eedbi('edit', path('v3.json'), 'cert', '-e', replacing_editor(pem.sub('MIIB', 'MIIC')))
    # Windows editors get CRLF line endings, which are read back as LF.
    assert_equal pem, File.binread(path('seen')).gsub("\r\n", "\n"), 'real line breaks, not \n escapes'
    assert_equal pem.sub('MIIB', 'MIIC'), decrypt('v3.json')['cert']
  end

  def test_key_opens_other_values_as_json
    eedbi('edit', path('v3.json'), 'nested', '-e', replacing_editor('{"user":"root"}'))
    assert_equal({ 'user' => 'admin', 'roles' => %w[read write] }, JSON.parse(File.read(path('seen'))))
    assert_equal({ 'user' => 'root' }, decrypt('v3.json')['nested'])
  end

  def test_key_with_json_edits_a_string_as_json
    eedbi('edit', path('v3.json'), 'password', '--json-value', '-e', replacing_editor('42'))
    assert_equal "\"hunter2\"\n", File.read(path('seen'))
    assert_equal 42, decrypt('v3.json')['password']

    eedbi('edit', path('v3.json'), 'added', '--json-value', '-e', replacing_editor('{"a":1}'))
    assert_equal "null\n", File.read(path('seen')), 'a new key opens as JSON'
    assert_equal({ 'a' => 1 }, decrypt('v3.json')['added'])
  end

  def test_key_creates_a_missing_key_and_item
    eedbi('edit', path('v3.json'), 'added', '-e', replacing_editor("new\n"))
    assert_equal 'new', decrypt('v3.json')['added']

    eedbi('edit', path('new.json'), 'password', '-e', replacing_editor('p'))
    assert_equal({ 'id' => 'new', 'password' => 'p' }, decrypt('new.json'))
  end

  def test_key_keeps_other_ciphertext
    before = read_json('v3.json')
    eedbi('edit', path('v3.json'), 'password', '-e', replacing_editor('changed'))
    (before.keys - %w[id password]).each { |key| assert_equal before[key], read_json('v3.json')[key], key }
  end

  def test_key_with_invalid_json_asks_again
    r = eedbi('edit', path('v3.json'), 'port', '-e', replacing_editor('{'), stdin: "n\n")
    assert_equal 1, r.status
    assert_match(/Unable to parse JSON\. Edit again/, r.err)
  end

  def test_key_id_and_json_without_key
    assert_match(/id is not encrypted/, eedbi('edit', path('v3.json'), 'id', '-e', ruby_editor('nil')).err)
    assert_match(/--json-value needs KEY/, eedbi('edit', path('v3.json'), '--json-value', '-e', ruby_editor('nil')).err)
  end

  def test_encrypt_version_converts_only_changed_values
    before = read_json('v1.json')
    r = eedbi('edit', path('v1.json'), '--encrypt-version', '3',
              '-e', ruby_editor("d = JSON.parse(File.read(path)); d['port'] = 1; File.write(path, JSON.generate(d))"))
    assert_equal report('v1.json', 'changed "port"'), r.out, r.err
    after = read_json('v1.json')
    assert_equal 3, after['port']['version']
    (before.keys - %w[id port]).each { |key| assert_equal before[key], after[key], key }
  end

  # Anything may change in the editor, so a version that would lower one of
  # the values is refused before it opens.
  def test_encrypt_version_that_would_lower_values_is_refused_before_editing
    opened = path('opened')
    r = eedbi('edit', path('v3.json'), '--encrypt-version', '1', '-e', ruby_editor("File.write(#{opened.inspect}, '')"))
    assert_equal 1, r.status
    assert_match(/would lower .* from version 3/, r.err)
    refute File.exist?(opened)
  end

  # null is a value like any other, not a sign that the edit was abandoned.
  def test_key_with_a_null_value
    before = File.read(path('v3.json'))
    r = eedbi('edit', path('v3.json'), 'none', '-e', ruby_editor('nil'))
    assert_equal [0, report('v3.json', 'no changes')], [r.status, r.out], r.err
    assert_equal before, File.read(path('v3.json'))

    eedbi('edit', path('v3.json'), 'password', '--json-value', '-e', replacing_editor('null'))
    assert_nil decrypt('v3.json').fetch('password')
  end

  # A new key opens empty, or as null with --json-value. Left that way, it
  # is not added, and a new item is not created.
  def test_key_left_empty_is_not_added
    before = File.read(path('v3.json'))
    [[], ['--json-value']].each do |options|
      r = eedbi('edit', path('v3.json'), 'added', *options, '-e', ruby_editor('nil'))
      assert_equal [0, report('v3.json', 'no changes')], [r.status, r.out], r.err
    end
    assert_equal before, File.read(path('v3.json'))

    r = eedbi('edit', path('new.json'), 'password', '-e', ruby_editor('nil'))
    assert_equal [0, report('new.json', 'no changes')], [r.status, r.out], r.err
    refute File.exist?(path('new.json'))
  end

  # As with a new key: an editor closed at once, such as a GUI editor that
  # does not wait, must not leave an item with only an id behind.
  def test_new_item_left_as_the_template_is_not_created
    r = eedbi('edit', path('new.json'), '-e', ruby_editor('nil'))
    assert_equal [0, report('new.json', 'no changes')], [r.status, r.out], r.err
    assert_match(/Hint: the editor returned after/, r.err)
    refute File.exist?(path('new.json'))

    File.write(path('empty.json'), "{}\n")
    eedbi('edit', path('empty.json'), '-e', ruby_editor('nil'))
    assert_equal "{}\n", File.read(path('empty.json'))
  end
end
