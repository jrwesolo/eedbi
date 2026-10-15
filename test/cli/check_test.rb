# frozen_string_literal: true

require_relative '../test_helper'

class CheckTest < Minitest::Test
  include EedbiTestHelper

  def test_every_fixture_passes
    names = %w[v0 v1 v2 v3 mixed].map { |name| path("#{name}.json") }
    r = eedbi('check', *names)
    assert_equal 0, r.status, r.out
    assert_match(/^ok    .*v0\.json \(version 0\)$/, r.out)
    assert_match(/^ok    .*mixed\.json \(versions 0, 1, 2, 3\)$/, r.out)
    refute_includes r.out, 'hunter2'
  end

  # knife data bag show and data_bag_item return such items undecrypted.
  def test_version_0_values_pass_with_a_warning
    r = eedbi('check', path('v0.json'), path('mixed.json'), path('v3.json'))
    assert_equal 0, r.status, r.err
    assert_equal 2, r.err.lines.size, r.err
    assert_includes r.err, "Warning: #{path('v0.json')}: version 0 values (\"password\", \"empty\", "
    assert_includes r.err, "): knife data bag show and chef-client's data_bag_item return this item without " \
                           'decrypting it; only EncryptedDataBagItem.load decrypts it. ' \
                           "Convert it with 'eedbi migrate #{path('v0.json')}'.\n"
    assert_match(/^Warning: .*mixed\.json: version 0 values \("password", "enabled", "nested"\)/, r.err)

    quiet = eedbi('check', path('mixed.json'), '--quiet', '--format', 'json')
    assert_equal r.err.lines.last, quiet.err, 'also with --quiet and JSON'
    full = JSON.parse(eedbi('check', path('mixed.json'), '--format', 'json').out)['items'].first
    assert_equal [r.err.lines.last.delete_prefix("Warning: #{path('mixed.json')}: ").chomp], full['warnings']
  end

  # yajl, which knife parses with, refuses it; eedbi reads it, so check is
  # where it is caught.
  def test_byte_order_mark_fails
    File.binwrite(path('bom.json'), "\xEF\xBB\xBF#{File.read(path('v3.json')).sub('"v3"', '"bom"')}")
    [eedbi('check', path('bom.json')), eedbi('check', path('bom.json'), '--no-decrypt', secret: false)].each do |r|
      assert_equal 1, r.status
      assert_includes r.out, "FAIL  #{path('bom.json')}: starts with a UTF-8 byte order mark, which knife cannot " \
                             "parse. Save it as UTF-8 without one, or run: perl -pi -e 's/^\xEF\xBB\xBF// " \
                             "if $. == 1' #{Shellwords.escape(path('bom.json'))}\n"
    end
    r = eedbi('check', '-', stdin: File.binread(path('bom.json')), interactive: false)
    assert_match(/^FAIL  stdin: starts with a UTF-8 byte order mark, which knife cannot parse$/, r.out)
  end

  def test_failures_are_reported_per_item
    r = eedbi('check', path('v3.json'), path('wrong_key.json'), path('plain.json'), path('missing.json'))
    assert_equal 1, r.status
    assert_match(/^ok    .*v3\.json/, r.out)
    assert_match(/^FAIL  .*wrong_key\.json: unable to decrypt/, r.out)
    assert_match(/^FAIL  .*plain\.json: unable to decrypt \("password": value is not encrypted\)/, r.out)
    assert_match(/^FAIL  .*missing\.json: file not found/, r.out)
    assert_match(/^3 of 4 items failed$/, r.out)
  end

  def test_min_version
    r = eedbi('check', '--decrypt-minimum-version', '2', path('v1.json'), path('mixed.json'), path('v2.json'))
    assert_equal 1, r.status
    assert_match(/^FAIL  .*v1\.json: uses encryption version 1 \(minimum 2\)$/, r.out)
    assert_match(/^FAIL  .*mixed\.json: uses encryption versions 0, 1 \(minimum 2\)$/, r.out)
    assert_match(/^ok    .*v2\.json/, r.out)
  end

  def test_no_decrypt_needs_no_secret
    with_env('ENCRYPTED_DATA_BAG_SECRET' => path('no_such_secret')) do
      names = %w[v1 v2 v3 wrong_key].map { |name| path("#{name}.json") }
      r = eedbi('check', '--no-decrypt', *names, secret: false)
      assert_equal 0, r.status, r.out
      assert_match(/^ok    .*wrong_key\.json \(version \d\)$/, r.out, 'decryption is not checked')

      r = eedbi('check', '--no-decrypt', path('plain.json'), path('v1.json'), '--decrypt-minimum-version', '2',
                secret: false)
      assert_equal 1, r.status
      assert_match(/^FAIL  .*plain\.json: not encrypted: "password", "empty", "port", /, r.out)
      assert_match(/^FAIL  .*v1\.json: uses encryption version 1 \(minimum 2\)$/, r.out)
    end
  end

  # A plaintext string of base64, such as a password from
  # 'openssl rand -base64 32', or a hex token, looks like version 0.
  def test_no_decrypt_fails_version_0
    password = ['p' * 32].pack('m0')
    File.write(path('leak.json'), JSON.generate('id' => 'leak', 'password' => password, 'token' => 'ab' * 32))
    r = eedbi('check', '--no-decrypt', path('leak.json'), path('mixed.json'), secret: false)
    assert_equal 1, r.status
    assert_match(/^FAIL  .*leak\.json: uses encryption version 0 \("password", "token"\), which plaintext can /, r.out)
    assert_match(/^FAIL  .*mixed\.json: uses encryption version 0 \("password", "enabled", "nested"\)/, r.out)
    assert_match(/^ok    .*mixed\.json/, eedbi('check', path('mixed.json')).out, 'fine with the secret')
  end

  # What decryption would reject anyway, found without the secret too, as
  # import does.
  def test_no_decrypt_checks_versions_and_ciphers
    good = read_json('v3.json')['password']
    {
      'version.json' => good.merge('version' => '9'),
      'cipher.json' => good.merge('cipher' => 'aes-256-cbc')
    }.each { |name, field| File.write(path(name), JSON.generate('id' => name.delete_suffix('.json'), 'a' => field)) }
    r = eedbi('check', '--no-decrypt', path('version.json'), path('cipher.json'), secret: false)
    assert_equal 1, r.status
    assert_match(/^FAIL  .*version\.json: "a": unsupported encryption version "9"$/, r.out)
    assert_match(/^FAIL  .*cipher\.json: "a": cipher "aes-256-cbc" is not valid for encryption version 3$/, r.out)
  end

  def test_missing_secret_is_reported_once
    with_env('ENCRYPTED_DATA_BAG_SECRET' => path('no_such_secret')) do
      r = eedbi('check', path('v1.json'), path('v3.json'), secret: false)
      assert_equal [1, ''], [r.status, r.out]
      assert_equal 1, r.err.lines.size, r.err
      assert_match(/Secret file not found/, r.err)
    end
  end

  def test_no_decrypt_refuses_a_secret
    r = eedbi('check', '--no-decrypt', path('v3.json'))
    assert_equal 2, r.status
    assert_match(/--no-decrypt uses no secret/, r.err)
  end

  def test_invalid_utf8_fails
    File.binwrite(path('bad.json'), "{\"id\":\"bad\",\"a\":\"\xFF\"}")
    [eedbi('check', path('bad.json')), eedbi('check', path('bad.json'), '--no-decrypt', secret: false)].each do |r|
      assert_equal 1, r.status, r.err
      assert_match(/^FAIL  .*bad\.json: not valid UTF-8, which JSON requires$/, r.out)
    end
  end

  def test_invalid_id_fails
    File.write(path('bad.json'), JSON.generate(read_json('v3.json').merge('id' => 'bad id')))
    assert_match(/^FAIL  .*bad\.json: invalid data bag item id/, eedbi('check', path('bad.json')).out)
  end

  # knife upload rejects these, so check does too.
  def test_id_must_match_the_file_name
    FileUtils.cp(path('v3.json'), path('renamed.json'))
    r = eedbi('check', path('renamed.json'))
    assert_equal 1, r.status
    assert_match(/^FAIL  .*renamed\.json: id must be 'renamed' to match the file name \(is 'v3'\)/, r.out)
  end

  # knife reads only *.json, and write and import keep the id of other files.
  def test_id_of_other_files_is_not_compared
    FileUtils.cp(path('v3.json'), path('v3.bak'))
    assert_equal 0, eedbi('check', path('v3.bak')).status
    File.write(path('bad.bak'), JSON.generate(read_json('v3.json').merge('id' => 'bad id')))
    assert_match(/^FAIL  .*bad\.bak: invalid data bag item id "bad id"/, eedbi('check', path('bad.bak')).out)
  end

  def test_invalid_minimum_from_the_environment_is_reported_once
    with_env('EEDBI_DECRYPT_MINIMUM_VERSION' => '9') do
      r = eedbi('check', path('v1.json'), path('v3.json'))
      assert_equal [1, ''], [r.status, r.out]
      assert_equal "Invalid $EEDBI_DECRYPT_MINIMUM_VERSION '9': use 0, 1, 2, 3\n", r.err
    end
  end

  def test_quiet_prints_only_failures
    r = eedbi('check', '--quiet', path('v3.json'), path('wrong_key.json'))
    assert_equal 1, r.status
    refute_match(/^ok/, r.out)
    assert_match(/^FAIL  .*wrong_key\.json/, r.out)
    assert_equal '', eedbi('check', '-q', path('v3.json')).out
  end

  # No file name to compare the id with.
  def test_item_from_stdin
    r = eedbi('check', '-', stdin: File.read(path('v3.json')), interactive: false)
    assert_equal 0, r.status, r.out
    assert_match(/^ok    stdin \(version 3\)$/, r.out)
    r = eedbi('check', '-', '--format', 'json', stdin: File.read(path('v3.json')), interactive: false)
    assert_equal '-', JSON.parse(r.out)['items'].first['path'], 'JSON keeps the argument as given'
    r = eedbi('check', '-', stdin: File.read(path('plain.json')), interactive: false)
    assert_match(/^FAIL  stdin: unable to decrypt/, r.out)
  end

  def test_json_format
    r = eedbi('check', '--format', 'json', path('v3.json'), path('mixed.json'), path('plain.json'))
    assert_equal 1, r.status
    result = JSON.parse(r.out)
    assert_equal({ 'checked' => 3, 'failed' => 1 }, result.except('items'))
    assert_equal({ 'path' => path('v3.json'), 'ok' => true, 'versions' => [3] }, result['items'][0])
    assert_equal [0, 1, 2, 3], result['items'][1]['versions']
    assert_equal false, result['items'][2]['ok']
    assert_match(/\Aunable to decrypt \("password": value is not encrypted\)/, result['items'][2]['error'])
    refute_includes r.out, 'hunter2'

    quiet = JSON.parse(eedbi('check', '--format', 'json', '--quiet', path('v3.json'), path('plain.json')).out)
    assert_equal([path('plain.json')], quiet['items'].map { |item| item['path'] })
    assert_equal 2, quiet['checked']
  end

  def test_text_format_is_the_default
    assert_equal eedbi('check', path('v3.json')).out, eedbi('check', '--format', 'text', path('v3.json')).out
    assert_equal 2, eedbi('check', '--format', 'xml', path('v3.json')).status
  end
end
