# frozen_string_literal: true

require_relative '../test_helper'

class WriteTest < Minitest::Test
  include EedbiTestHelper

  def write(name, json, *args)
    eedbi('write', path(name), *args, stdin: json.is_a?(String) ? json : JSON.generate(json), interactive: false)
  end

  def test_creates_a_new_item_in_the_default_version
    r = write('new.json', plain('new'))
    assert_equal 0, r.status, r.err
    assert_match(/new\.json: created the item with "password", "empty", /, r.out)
    assert_equal [Eedbi::Crypto::DEFAULT_VERSION], versions('new.json')
    assert_equal plain('new'), decrypt('new.json')
    refute_includes File.read(path('new.json')), 'hunter2'
    assert File.read(path('new.json')).end_with?("}\n")
  end

  def test_reports_the_changed_key_names
    item = plain('v3').except('port').merge('password' => 'changed', 'new' => 1)
    assert_equal report('v3.json', 'added "new", changed "password", removed "port"'), write('v3.json', item).out
    reordered = { 'id' => 'v3' }.merge(item.except('id').to_a.reverse.to_h)
    assert_equal report('v3.json', 'reordered the keys'), write('v3.json', reordered).out
  end

  # The command most likely to remove keys by mistake: a partial JSON
  # replaces the whole item.
  def test_dry_run
    before = File.read(path('v3.json'))
    r = write('v3.json', { 'id' => 'v3', 'password' => 'hunter2' }, '--dry-run')
    assert_equal 0, r.status, r.err
    assert_match(/v3\.json: would remove "empty", /, r.out)
    assert_equal before, File.read(path('v3.json'))
    assert_equal report('new.json', 'would create the item with "a"'),
                 write('new.json', { 'id' => 'new', 'a' => 1 }, '--dry-run').out
    refute File.exist?(path('new.json'))
  end

  def test_default_version_comes_from_the_environment
    with_env('EEDBI_DEFAULT_ENCRYPT_VERSION' => '2') do
      write('new.json', plain('new'))
      write('v1.json', plain('v1').merge('port' => 1))
    end
    assert_equal [2], versions('new.json')
    assert_equal [1], versions('v1.json'), 'an existing item keeps its version'
  end

  def test_invalid_default_version
    with_env('EEDBI_DEFAULT_ENCRYPT_VERSION' => '9') do
      r = write('new.json', plain('new'))
      assert_equal 1, r.status
      assert_match(/new\.json: invalid \$EEDBI_DEFAULT_ENCRYPT_VERSION '9'/, r.err)
    end
  end

  [1, 2, 3].each do |version|
    define_method("test_existing_v#{version}_item_keeps_its_version") do
      name = "v#{version}"
      write("#{name}.json", plain(name).merge('port' => 1))
      assert_equal [version], versions("#{name}.json")
    end
  end

  def test_each_version_has_chefs_fields
    { 1 => %w[encrypted_data iv version cipher],
      2 => %w[encrypted_data hmac iv version cipher],
      3 => %w[encrypted_data iv auth_tag version cipher] }.each do |version, keys|
      with_env('EEDBI_DEFAULT_ENCRYPT_VERSION' => version.to_s) do
        write("f#{version}.json", { 'id' => "f#{version}", 'k' => 1 })
      end
      assert_equal keys, read_json("f#{version}.json")['k'].keys, "version #{version}"
    end
  end

  def test_identical_content_is_not_written
    before = File.read(path('v3.json'))
    r = write('v3.json', plain('v3'))
    assert_equal report('v3.json', 'no changes'), r.out
    assert_equal before, File.read(path('v3.json'))
  end

  def test_key_order_counts_as_a_change
    reordered = plain('v3').to_a.reverse.to_h
    write('v3.json', reordered)
    assert_equal ['id', *(reordered.keys - ['id'])], read_json('v3.json').keys, 'id first, the rest as given'
  end

  def test_id_is_written_first
    write('new.json', { 'a' => 1, 'id' => 'new', 'b' => 2 })
    assert_equal %w[id a b], read_json('new.json').keys
  end

  # Only a real change moves the id; an otherwise identical item is left alone.
  def test_id_elsewhere_alone_is_not_a_change
    item = read_json('v3.json')
    File.write(path('v3.json'), JSON.pretty_generate(item.except('id').merge('id' => 'v3')))
    before = File.read(path('v3.json'))
    assert_equal report('v3.json', 'no changes'), write('v3.json', plain('v3')).out
    assert_equal before, File.read(path('v3.json'))

    write('v3.json', plain('v3').merge('port' => 1))
    assert_equal 'id', read_json('v3.json').keys.first
  end

  def test_only_changed_values_get_new_ciphertext
    before = read_json('v3.json')
    write('v3.json', plain('v3').merge('password' => 'changed'))
    after = read_json('v3.json')
    refute_equal before['password'], after['password']
    (before.keys - %w[id password]).each { |key| assert_equal before[key], after[key], key }
  end

  def test_keys_can_be_added_and_removed
    data = plain('v3').except('list').merge('added' => 'new')
    write('v3.json', data)
    assert_equal data, decrypt('v3.json')
  end

  # Version 0 cannot be written, so only the changed value moves, to the
  # default version; the rest keep their ciphertext.
  def test_changed_version_0_value_takes_the_default_version
    before = read_json('v0.json')
    with_env('EEDBI_DEFAULT_ENCRYPT_VERSION' => '2') do
      write('v0.json', plain('v0').merge('password' => 'changed', 'added' => 'new'))
    end
    after = read_json('v0.json')
    assert_equal [2, 2], [after['password']['version'], after['added']['version']]
    (before.keys - %w[id password]).each { |key| assert_equal before[key], after[key], key }
    assert_equal plain('v0').merge('password' => 'changed', 'added' => 'new'), decrypt('v0.json')
  end

  # Version 0 values take the item's highest version, which everything that
  # reads the item can already read, rather than the default.
  def test_changed_version_0_value_in_a_mixed_item_takes_its_highest_version
    with_env('EEDBI_DEFAULT_ENCRYPT_VERSION' => '1') do
      write('mixed.json', plain('mixed').merge('password' => 'changed'))
    end
    assert_equal 3, read_json('mixed.json')['password']['version']
  end

  # Only migrate converts whole items: a change re-encrypts just the changed
  # values, each in its own version, and new keys in the highest version.
  def test_changes_in_a_mixed_item_keep_each_values_version
    before = read_json('mixed.json')
    write('mixed.json', plain('mixed').merge('port' => 1, 'unicode' => 'x', 'added' => 'new'))
    after = read_json('mixed.json')
    assert_equal({ 'port' => 2, 'unicode' => 1, 'added' => 3 },
                 %w[port unicode added].to_h { |key| [key, after[key]['version']] })
    (before.keys - %w[id port unicode]).each { |key| assert_equal before[key], after[key], key }
  end

  def test_encrypt_version_applies_to_changed_and_new_values_only
    before = read_json('v1.json')
    r = write('v1.json', plain('v1').merge('port' => 1, 'added' => 'new'), '--encrypt-version', '3')
    assert_equal 0, r.status, r.err
    after = read_json('v1.json')
    assert_equal [3, 3], [after['port']['version'], after['added']['version']]
    (before.keys - %w[id port]).each { |key| assert_equal before[key], after[key], key }

    r = write('v1.json', plain('v1').merge('port' => 1, 'added' => 'new'), '--encrypt-version', '3')
    assert_equal report('v1.json', 'no changes'), r.out, 'nothing changed, so nothing is converted'
  end

  def test_encrypt_version_never_lowers_a_value
    before = File.read(path('v3.json'))
    r = write('v3.json', plain('v3').merge('port' => 1), '--encrypt-version', '1')
    assert_equal 1, r.status
    assert_match(/v3\.json: --encrypt-version 1 would lower "port" from version 3\. /, r.err)
    assert_match(/migrate --encrypt-version 1 --allow-downgrade/, r.err)
    assert_equal before, File.read(path('v3.json'))
    assert_equal 0, write('v3.json', plain('v3').merge('added' => 1), '--encrypt-version', '1').status,
                 'a new key lowers nothing'
  end

  def test_invalid_input
    { '[]' => 'JSON from stdin must be an object', '{' => 'unable to parse JSON from stdin',
      '{"id":"new","a":{"x":1,"x":2}}' => 'duplicate key "x"' }.each do |json, message|
      r = write('new.json', json)
      assert_equal 1, r.status, json
      assert_includes r.err, "new.json: #{message}"
      refute File.exist?(path('new.json')), json
    end
  end

  def test_byte_order_mark_is_accepted
    r = write('new.json', "\xEF\xBB\xBF{\"id\":\"new\"}".b)
    assert_equal 0, r.status, r.err
  end

  # The file name decides the id, as knife upload requires. An id from
  # elsewhere gets a note, since it may mean the wrong file.
  def test_id_comes_from_the_file_name
    r = write('new.json', plain('staging'))
    assert_equal [0, report('new.json', 'created the item with "password", "empty", "port", "ratio", "enabled", ' \
                                        '"disabled", "none", "list", "nested", "unicode"')], [r.status, r.out]
    assert_equal "Note: id 'staging' from the input replaced with 'new', from the file name\n", r.err
    assert_equal 'new', read_json('new.json')['id']

    r = write('new.json', plain('new').except('id').merge('password' => 'x'))
    assert_equal [report('new.json', 'changed "password"'), ''], [r.out, r.err], 'a missing id is filled in'

    File.write(path('old.json'), JSON.generate(read_json('v3.json')))
    r = write('old.json', plain('v3').merge('password' => 'x'))
    assert_equal [report('old.json', %(changed "password", changed id 'v3' to 'old')), ''], [r.out, r.err]
    assert_equal report('old.json', 'no changes'), write('old.json', plain('old').merge('password' => 'x')).out

    r = write('bad id.json', plain('x'))
    assert_equal 1, r.status
    assert_match(/bad id\.json: the file name gives an invalid item id 'bad id'/, r.err)
  end

  # knife reads only *.json, so another file's id is its own business.
  def test_id_mismatch_warning_only_for_json_files
    File.write(path('elsewhere.json'), JSON.generate(read_json('v3.json')))
    assert_equal "Warning: id 'v3' does not match file name 'elsewhere'\n",
                 eedbi('set', path('elsewhere.json'), 'a', stdin: 'x', interactive: false).err

    FileUtils.cp(path('v3.json'), path('v3.item'))
    r = write('v3.item', plain('v3').merge('password' => 'x'))
    assert_equal [report('v3.item', 'changed "password"'), ''], [r.out, r.err]
  end

  def test_id_is_reported_with_its_values
    File.write(path('empty.json'), "{}\n")
    assert_equal report('empty.json', %(added "a", set id 'empty')), write('empty.json', 'a' => 1).out
    File.write(path('moved.json'), JSON.generate('id' => 'elsewhere', 'a' => read_json('v3.json')['port']))
    r = eedbi('write', path('moved.json'), '--dry-run', stdin: '{"a":5432}', interactive: false)
    assert_equal report('moved.json', %(would change id 'elsewhere' to 'moved')), r.out
  end

  def test_wrong_secret_does_not_overwrite
    before = File.read(path('v3.json'))
    r = eedbi('write', path('v3.json'), '-s', path('other_secret'), secret: false, stdin: '{"id":"v3"}',
                                                                    interactive: false)
    assert_equal 1, r.status
    assert_equal before, File.read(path('v3.json'))
  end

  def test_refuses_a_terminal_on_stdin
    r = eedbi('write', path('new.json'), interactive: true)
    assert_equal 1, r.status
    assert_match(/eedbi write reads the item from stdin, but stdin is a terminal\. Pipe it in/, r.err)
  end

  def test_from_file
    File.write(path('plain_in.json'), JSON.generate(plain('new')))
    r = eedbi('write', path('new.json'), '--from-file', path('plain_in.json'), interactive: true)
    assert_equal 0, r.status, r.err
    assert_equal plain('new'), decrypt('new.json')
    r = eedbi('write', path('new.json'), '--from-file', path('missing'))
    assert_match(/new\.json: input file not found/, r.err)
    r = eedbi('write', path('new.json'), '--from-file', '-', stdin: '{"id":"new"}', interactive: false)
    assert_equal 0, r.status, r.err
  end

  def test_empty_input
    assert_match(/\A.*new\.json: stdin is empty \(expected the item as JSON\)/, write('new.json', " \n").err)
    File.write(path('empty.json'), '')
    r = eedbi('write', path('new.json'), '--from-file', path('empty.json'))
    assert_match(/empty\.json is empty \(expected the item as JSON\)/, r.err)
  end

  def test_missing_directory
    r = write(File.join('missing', 'new.json'), { 'id' => 'new' })
    assert_equal 1, r.status
    assert_match(/new\.json: directory not found/, r.err)
  end

  # Stdin that changes the item on disk while it is being read, standing in
  # for a slow producer at the other end of a pipe.
  class ChangingInput < StringIO
    def initialize(content, file)
      super(content)
      @file = file
    end

    def read(*)
      File.write(@file, "#{File.read(@file)} ")
      super
    end
  end

  def test_item_changed_while_reading_stdin_is_not_overwritten
    err = StringIO.new
    status = Eedbi.main(['write', path('v3.json'), '-s', path('encrypted_data_bag_secret')],
                        stdin: ChangingInput.new('{"id":"v3","a":1}', path('v3.json')),
                        stdout: StringIO.new, stderr: err, interactive: false)
    assert_equal 1, status
    assert_match(/changed on disk while eedbi was running\. Nothing was written/, err.string)
  end

  # Most likely an encrypted item piped in by mistake, as from git show.
  # import copies it as is; --force writes it anyway.
  def test_encrypted_input_needs_force
    before = File.read(path('v3.json'))
    r = write('v3.json', File.read(path('v2.json')))
    assert_equal 1, r.status
    assert_match(/\A[^\n]*v3\.json: every changed value looks encrypted already[^\n]*pass --force\.\n\z/,
                 r.err, 'no note about the id when nothing is written')
    assert_equal before, File.read(path('v3.json'))

    r = write('v3.json', File.read(path('v2.json')), '--force')
    assert_equal 0, r.status, r.err
    assert_equal 2, decrypt('v3.json')['password']['version']
    assert_equal 0, write('v3.json', plain('v3').merge('password' => 'x')).status
  end
end
