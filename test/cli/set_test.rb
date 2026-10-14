# frozen_string_literal: true

require_relative '../test_helper'

class SetTest < Minitest::Test
  include EedbiTestHelper

  def set(*args, stdin: '', **options)
    eedbi('set', *args, stdin: stdin, interactive: false, **options)
  end

  def test_sets_a_string_from_stdin_without_the_trailing_newline
    before = read_json('v3.json')
    r = set(path('v3.json'), 'password', stdin: "changed\n")
    assert_equal report('v3.json', 'changed "password"'), r.out, r.err
    assert_equal 'changed', decrypt('v3.json')['password']
    (before.keys - %w[id password]).each { |key| assert_equal before[key], read_json('v3.json')[key], key }
  end

  def test_only_one_newline_is_removed
    set(path('v3.json'), 'password', stdin: "two\n\n")
    assert_equal "two\n", decrypt('v3.json')['password']
  end

  def test_json_values
    set(path('v3.json'), 'port', '--json-value', stdin: '1234')
    set(path('v3.json'), 'nested', '--json-value', stdin: '{"a":[true,null]}')
    assert_equal 1234, decrypt('v3.json')['port']
    assert_equal({ 'a' => [true, nil] }, decrypt('v3.json')['nested'])
    r = set(path('v3.json'), 'port', '--json-value', stdin: '{')
    assert_match(/v3\.json: the value for "port" is not valid JSON/, r.err)
  end

  # An empty value is never JSON, so the two together are a mistake.
  # --allow-empty cannot help here, so it is not suggested.
  def test_empty_json_value_points_at_an_empty_json_string
    r = set(path('v3.json'), 'port', '--json-value', stdin: '')
    assert_equal 1, r.status
    assert_match(/from stdin is empty\. An empty value is not JSON; an empty string is ""\.\n\z/, r.err)
    assert_equal 0, set(path('v3.json'), 'port', '--json-value', stdin: '""').status
    assert_equal '', decrypt('v3.json')['port']
  end

  def test_json_value_with_allow_empty_is_a_usage_error
    r = set(path('v3.json'), 'port', '--json-value', '--allow-empty', stdin: '')
    assert_equal 2, r.status
    assert_match(/--allow-empty and --json-value cannot be combined/, r.err)
  end

  def test_adds_a_new_key_and_creates_a_new_item
    set(path('v3.json'), 'added', stdin: 'x')
    assert_equal 'x', decrypt('v3.json')['added']

    set(path('new.json'), 'password', stdin: 'p')
    assert_equal({ 'id' => 'new', 'password' => 'p' }, decrypt('new.json'))
    assert_equal [Eedbi::Crypto::DEFAULT_VERSION], versions('new.json')
  end

  def test_same_value_is_not_written
    before = File.read(path('v3.json'))
    assert_equal report('v3.json', 'no changes'), set(path('v3.json'), 'password', stdin: 'hunter2').out
    assert_equal before, File.read(path('v3.json'))
  end

  def test_keeps_the_item_version
    set(path('v1.json'), 'password', stdin: 'x')
    assert_equal [1], versions('v1.json')
  end

  # A terminal on stdin means a person about to type the value.
  def test_terminal_on_stdin_prompts_twice
    console = FakeConsole.new('typed')
    r = eedbi('set', path('v3.json'), 'password', interactive: true, console: console)
    assert_equal 0, r.status, r.err
    assert_equal 'typed', decrypt('v3.json')['password']
    assert_equal ['Value for "password": ', 'Repeat value for "password": '], console.prompts
  end

  def test_prompt_mismatch_writes_nothing
    before = File.read(path('v3.json'))
    r = eedbi('set', path('v3.json'), 'password', interactive: true, console: FakeConsole.new('a', 'b'))
    assert_equal 1, r.status
    assert_match(/v3\.json: the values for "password" do not match/, r.err)
    assert_equal before, File.read(path('v3.json'))
  end

  def test_id_cannot_be_set
    assert_match(/id is not encrypted/, set(path('v3.json'), 'id', stdin: 'x').err)
  end

  def test_needs_item_and_key
    assert_match(/needs ITEM and KEY \(received 1 argument\)/, set(path('v3.json')).err)
    assert_match(/received 3/, set(path('v3.json'), 'a', 'b').err)
  end

  def test_dry_run_says_what_would_change
    before = File.read(path('v3.json'))
    assert_equal report('v3.json', 'would change "password"'),
                 set(path('v3.json'), 'password', '--dry-run', stdin: 'x').out
    assert_equal report('v3.json', 'would add "cert"'), set(path('v3.json'), 'cert', '--dry-run', stdin: 'x').out
    assert_equal report('v3.json', 'no changes'), set(path('v3.json'), 'password', '--dry-run', stdin: 'hunter2').out
    assert_equal before, File.read(path('v3.json'))
    assert_equal report('new.json', 'would create the item with "cert"'),
                 set(path('new.json'), 'cert', '--dry-run', stdin: 'x').out
    assert_equal report('new.json', 'created the item with "cert"'), set(path('new.json'), 'cert', stdin: 'x').out
  end

  def test_from_file_keeps_the_bytes_exactly
    File.binwrite(path('cert.pem'), "line 1\r\nline 2\n")
    r = set(path('v3.json'), 'cert', '--from-file', path('cert.pem'))
    assert_equal 0, r.status, r.err
    assert_equal "line 1\r\nline 2\n", decrypt('v3.json')['cert']

    set(path('v3.json'), 'piped', '--from-file', '-', stdin: "exact\n")
    assert_equal "exact\n", decrypt('v3.json')['piped']
  end

  # Nothing is read from a terminal or prompted for: the file was asked for.
  def test_from_file_ignores_a_terminal_unless_it_is_stdin
    File.write(path('value.txt'), 'from file')
    r = eedbi('set', path('v3.json'), 'a', '--from-file', path('value.txt'), interactive: true)
    assert_equal 0, r.status, r.err
    assert_equal 'from file', decrypt('v3.json')['a']
    r = eedbi('set', path('v3.json'), 'a', '--from-file', '-', interactive: true)
    assert_match(/reads stdin \(--from-file -\), but stdin is a terminal/, r.err)
  end

  def test_from_file_errors_and_json
    assert_match(/v3\.json: input file not found/, set(path('v3.json'), 'a', '--from-file', path('missing')).err)
    assert_match(/is a directory/, set(path('v3.json'), 'a', '--from-file', @dir).err)
    File.write(path('number.txt'), "42\n")
    set(path('v3.json'), 'n', '--from-file', path('number.txt'), '--json-value')
    assert_equal 42, decrypt('v3.json')['n']
  end

  def test_binary_data_is_rejected
    r = set(path('v3.json'), 'blob', '--from-file', '-', stdin: "\xFF\xFE".b)
    assert_equal 1, r.status
    assert_match(/v3\.json: the value for "blob" is not valid UTF-8/, r.err)
  end

  def test_old_input_options_are_gone
    %w[--raw --prompt --json].each do |option|
      assert_equal 2, set(path('v3.json'), 'a', option, stdin: '1').status, option
    end
  end

  # An unset variable or a script without stdin must not store an empty
  # secret.
  def test_empty_stdin_needs_allow_empty
    before = File.read(path('v3.json'))
    ['', "\n"].each do |input|
      r = set(path('v3.json'), 'password', stdin: input)
      assert_equal 1, r.status, input.inspect
      assert_match(/v3\.json: the value for "password" from stdin is empty\. To set an empty string/, r.err)
    end
    File.write(path('empty.txt'), '')
    r = set(path('v3.json'), 'password', '--from-file', path('empty.txt'))
    assert_match(/v3\.json: the value for "password" from .*empty\.txt is empty/, r.err)
    assert_equal before, File.read(path('v3.json'))

    assert_equal 0, set(path('v3.json'), 'password', '--allow-empty', stdin: "\n").status
    assert_equal '', decrypt('v3.json')['password']
    assert_equal 0, set(path('v3.json'), 'cert', '--from-file', '-', stdin: "\n").status,
                 'an exact newline is not empty'
  end

  def test_prompt_value_is_not_stripped_and_may_be_empty
    eedbi('set', path('v3.json'), 'spaced', interactive: true, console: FakeConsole.new(' padded '))
    eedbi('set', path('v3.json'), 'blank', interactive: true, console: FakeConsole.new(''))
    assert_equal [' padded ', ''], decrypt('v3.json').values_at('spaced', 'blank')
  end

  def test_encrypt_version_converts_only_the_value_set
    before = read_json('v1.json')
    r = set(path('v1.json'), 'password', '--encrypt-version', '3', stdin: 'x')
    assert_equal 0, r.status, r.err
    after = read_json('v1.json')
    assert_equal 3, after['password']['version']
    (before.keys - %w[id password]).each { |key| assert_equal before[key], after[key], key }

    r = set(path('v3.json'), 'password', '--encrypt-version', '2', stdin: 'x')
    assert_equal 1, r.status
    assert_match(/v3\.json: --encrypt-version 2 would lower "password" from version 3/, r.err)
  end

  # Under LANG=C, Ruby labels stdin US-ASCII; the bytes are still UTF-8.
  def test_stdin_is_utf8_whatever_the_locale
    r = set(path('v3.json'), 'password', stdin: (+"caf\u00e9").force_encoding(Encoding::US_ASCII))
    assert_equal 0, r.status, r.err
    assert_equal "caf\u00e9", decrypt('v3.json')['password']
  end
end
