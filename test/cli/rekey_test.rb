# frozen_string_literal: true

require_relative '../test_helper'
require 'yaml'

class RekeyTest < Minitest::Test
  include EedbiTestHelper

  def rekey(*names, new_secret: path('other_secret'))
    eedbi('rekey', *names.map { |name| path(name) }, '--new-secret-file', new_secret)
  end

  def test_items_move_to_the_new_secret
    r = rekey('v1.json', 'v2.json', 'v3.json')
    assert_equal 0, r.status, r.err
    %w[v1 v2 v3].each do |name|
      assert_equal plain(name), decrypt("#{name}.json", secret('other_secret')), name
      assert_raises(Eedbi::DecryptionError, name) { decrypt("#{name}.json") }
      assert_match(/#{name}\.json: encrypted with the new secret/, r.out)
    end
    assert_equal [1], versions('v1.json'), 'keeps the version'
  end

  # rekey changes the secret and nothing else; converting is migrate's job.
  def test_each_value_keeps_its_version
    item = read_json('v3.json').merge('password' => read_json('v1.json')['password'])
    File.write(path('both.json'), JSON.generate(item.merge('id' => 'both')))
    assert_equal 0, rekey('both.json').status
    after = read_json('both.json')
    assert_equal 1, after['password']['version']
    others = after.except('id', 'password').values.map { |field| field['version'] }
    assert_equal [3], others.uniq
    assert_equal plain('both'), decrypt('both.json', secret('other_secret'))
    assert_match(/invalid option: --encrypt-version/, eedbi('rekey', path('v1.json'), '--encrypt-version', '3').err)
  end

  def test_version_0_needs_migrate_first
    before = File.read(path('v3.json'))
    r = rekey('v3.json', 'mixed.json')
    assert_equal 1, r.status
    assert_match(/mixed\.json: uses encryption version 0 \("password", "enabled", "nested"\), which cannot/, r.err)
    assert_match(/Run 'eedbi migrate .*mixed\.json' first/, r.err)
    assert_equal before, File.read(path('v3.json'))
  end

  def test_needs_a_new_secret
    r = eedbi('rekey', path('v3.json'))
    assert_equal 2, r.status
    assert_match(/needs --new-secret-file or --new-secret-prompt/, r.err)
  end

  def test_same_secret_is_refused
    r = rekey('v3.json', new_secret: path('encrypted_data_bag_secret'))
    assert_equal 1, r.status
    assert_match(/same as the current one/, r.err)
  end

  def test_missing_new_secret_file
    r = rekey('v3.json', new_secret: path('missing'))
    assert_equal 1, r.status
    assert_match(/Secret file not found/, r.err)
  end

  # Half the items under one secret and half under another would be a mess.
  def test_nothing_is_written_when_any_item_fails
    before = File.read(path('v3.json'))
    File.write(path('third_secret'), 'a third secret')
    r = rekey('v3.json', 'wrong_key.json', new_secret: path('third_secret'))
    assert_equal 1, r.status
    assert_match(/wrong_key\.json: unable to decrypt .* Is this the right secret\?/, r.err)
    assert_match(/Nothing was written \(1 of 2 items failed\)/, r.err)
    assert_equal before, File.read(path('v3.json'))
  end

  # After an interrupted run, running rekey again finishes the job.
  def test_items_already_on_the_new_secret_are_left_alone
    rekey('v3.json')
    before = File.read(path('v3.json'))
    r = rekey('v3.json', 'v2.json', 'wrong_key.json')
    assert_equal 0, r.status, r.err
    assert_equal [report('v3.json', 'already uses the new secret'), report('v2.json', 'encrypted with the new secret'),
                  report('wrong_key.json', 'already uses the new secret')].join, r.out
    assert_equal before, File.read(path('v3.json'))
    assert_equal plain('v2'), decrypt('v2.json', secret('other_secret'))
  end

  def test_a_failed_write_does_not_stop_the_others
    names = %w[v1 v2 v3].map { |name| path("#{name}.json") }
    r = eedbi('rekey', *names, '--new-secret-file', path('other_secret'), stdout: stdout_changing(path('v2.json')))
    assert_equal 1, r.status
    assert_equal %w[v1 v3].map { |name| report("#{name}.json", 'encrypted with the new secret') }.join, r.out
    assert_match(/v2\.json changed on disk .*; not written\n1 of 3 items was not written\. Run the same/, r.err)

    r = rekey('v1.json', 'v2.json', 'v3.json')
    assert_equal 0, r.status, r.err
    assert_equal report('v2.json', 'encrypted with the new secret'), r.out.lines[1]
    %w[v1 v2 v3].each { |name| assert_equal plain(name), decrypt("#{name}.json", secret('other_secret')) }
  end

  def test_closed_output_pipe_stops_quietly
    r = eedbi('rekey', path('v2.json'), path('v3.json'), '--new-secret-file', path('other_secret'),
              stdout: stdout_closed)
    assert_equal [141, ''], [r.status, r.err]
    assert_equal plain('v2'), decrypt('v2.json', secret('other_secret'))
    assert_equal plain('v3'), decrypt('v3.json')

    r = rekey('v2.json', 'v3.json')
    assert_equal [report('v2.json', 'already uses the new secret'),
                  report('v3.json', 'encrypted with the new secret')].join, r.out
  end

  # A usage error, found before the current secret is read.
  def test_new_secret_cannot_come_from_stdin
    with_env('ENCRYPTED_DATA_BAG_SECRET' => path('no_such_secret')) do
      r = eedbi('rekey', path('v3.json'), '--new-secret-file', '-', secret: false)
      assert_equal 2, r.status
      assert_match(/\AThe secret cannot come from stdin/, r.err)
    end
  end

  def test_invalid_minimum_from_the_environment_is_reported_once
    with_env('EEDBI_DECRYPT_MINIMUM_VERSION' => '9') do
      r = rekey('v1.json', 'v3.json')
      assert_equal [1, "Invalid $EEDBI_DECRYPT_MINIMUM_VERSION '9': use 0, 1, 2, 3\n"], [r.status, r.err]
    end
  end

  # Chef cannot read an item with values under two secrets either.
  def test_item_with_values_under_both_secrets_fails
    item = read_json('v3.json').merge('password' => read_json('wrong_key.json')['password'])
    File.write(path('both.json'), JSON.generate(item.merge('id' => 'both')))
    r = rekey('both.json')
    assert_equal 1, r.status
    assert_match(/both\.json: unable to decrypt \("password": decryption failed\)/, r.err)
  end

  # Version 0 has no integrity check, so decrypting with the new secret
  # proves nothing.
  def test_version_0_item_is_never_taken_as_rekeyed
    cipher = OpenSSL::Cipher.new('aes-256-cbc').encrypt
    cipher.pkcs5_keyivgen(secret('other_secret'))
    value = [cipher.update('value'.to_yaml) + cipher.final].pack('m')
    File.write(path('old.json'), JSON.generate('id' => 'old', 'password' => value))
    r = rekey('old.json')
    assert_equal 1, r.status
    assert_match(/old\.json: unable to decrypt/, r.err)
  end

  def test_new_secret_prompt_asks_twice
    console = FakeConsole.new('typed new secret')
    r = eedbi('rekey', path('v3.json'), '--new-secret-prompt', console: console)
    assert_equal 0, r.status, r.err
    assert_equal plain('v3'), decrypt('v3.json', 'typed new secret')
    assert_equal ['New encrypted data bag secret: ', 'Repeat new encrypted data bag secret: '], console.prompts
  end

  def test_new_secret_prompt_mismatch_writes_nothing
    before = File.read(path('v3.json'))
    r = eedbi('rekey', path('v3.json'), '--new-secret-prompt', console: FakeConsole.new('one', 'two'))
    assert_match(/do not match/, r.err)
    assert_equal before, File.read(path('v3.json'))
  end

  def test_new_secret_file_and_prompt_are_exclusive
    r = eedbi('rekey', path('v3.json'), '--new-secret-file', path('other_secret'), '--new-secret-prompt',
              console: FakeConsole.new('x'))
    assert_match(/Choose one of --new-secret-file and --new-secret-prompt/, r.err)
  end

  def test_item_without_an_id_is_refused
    File.write(path('noid.json'), JSON.generate(read_json('v3.json').except('id')))
    r = eedbi('rekey', path('noid.json'), '--new-secret-file', path('other_secret'))
    assert_equal 1, r.status
    assert_match(/noid\.json: data bag item is missing an 'id'/, r.err)
  end

  def test_item_without_values
    File.write(path('empty.json'), %({\n  "id": "empty"\n}\n))
    before = File.read(path('empty.json'))
    r = eedbi('rekey', path('empty.json'), path('v3.json'), '--new-secret-file', path('other_secret'))
    assert_equal "#{report('empty.json', 'no values to encrypt')}" \
                 "#{report('v3.json', 'encrypted with the new secret')}", r.out
    assert_equal before, File.read(path('empty.json'))
  end

  def test_dry_run
    before = File.read(path('v3.json'))
    r = eedbi('rekey', path('v3.json'), '--new-secret-file', path('other_secret'), '--dry-run')
    assert_match(/v3\.json: would be encrypted with the new secret/, r.out)
    assert_match(/Dry run: nothing was written/, r.out)
    assert_equal before, File.read(path('v3.json'))
  end

  def test_an_item_named_twice_is_rekeyed_once
    r = rekey('v3.json', 'v3.json', 'v2.json')
    assert_equal 0, r.status, r.err
    assert_equal 2, r.out.lines.size
    %w[v2 v3].each { |name| assert_equal plain(name), decrypt("#{name}.json", secret('other_secret')) }
  end

  # A wrong current secret is found before the new one is typed twice.
  def test_current_secret_is_prompted_first
    console = FakeConsole.new(secret, 'typed new secret', 'typed new secret')
    r = eedbi('rekey', path('v3.json'), '--secret-prompt', '--new-secret-prompt', console: console, secret: false)
    assert_equal 0, r.status, r.err
    assert_equal ['Encrypted data bag secret: ', 'New encrypted data bag secret: ',
                  'Repeat new encrypted data bag secret: '], console.prompts
  end
end
