# frozen_string_literal: true

require_relative '../test_helper'

class MigrateTest < Minitest::Test
  include EedbiTestHelper

  def test_converts_items_to_a_version
    r = eedbi('migrate', '--encrypt-version', '3', path('v1.json'), path('mixed.json'), path('v3.json'))
    assert_equal 0, r.status, r.err
    assert_match(/v1\.json: converted version 1 -> 3/, r.out)
    assert_match(/mixed\.json: converted version 0, 1, 2, 3 -> 3/, r.out)
    assert_match(/v3\.json: already version 3/, r.out)
    %w[v1 mixed v3].each do |name|
      assert_equal [3], versions("#{name}.json"), name
      assert_equal plain(name), decrypt("#{name}.json"), name
    end
  end

  def test_defaults_to_the_default_version
    eedbi('migrate', path('v0.json'))
    assert_equal [Eedbi::Crypto::DEFAULT_VERSION], versions('v0.json')

    with_env('EEDBI_DEFAULT_ENCRYPT_VERSION' => '2') { eedbi('migrate', path('v1.json')) }
    assert_equal [2], versions('v1.json')
  end

  def test_values_already_in_the_version_keep_their_ciphertext
    before = read_json('mixed.json')
    eedbi('migrate', path('mixed.json'))
    after = read_json('mixed.json')
    before.each { |key, field| assert_equal field, after[key], key if field.is_a?(Hash) && field['version'] == 3 }
  end

  # Lowering a version weakens the encryption, so it has to be asked for.
  def test_downgrade_needs_allow_downgrade
    before = File.read(path('mixed.json'))
    r = eedbi('migrate', '--encrypt-version', '2', path('mixed.json'), path('v1.json'))
    assert_equal 1, r.status
    assert_match(/mixed\.json: would lower "ratio", "list" from version 3 to 2\. Pass --allow-downgrade/, r.err)
    assert_match(/Nothing was written \(1 of 2 items failed\)/, r.err)
    assert_equal before, File.read(path('mixed.json'))

    r = eedbi('migrate', '--encrypt-version', '2', '--allow-downgrade', path('mixed.json'))
    assert_equal 0, r.status, r.err
    assert_equal [2], versions('mixed.json')
    assert_equal plain('mixed'), decrypt('mixed.json')
  end

  def test_default_version_does_not_downgrade_either
    with_env('EEDBI_DEFAULT_ENCRYPT_VERSION' => '1') do
      assert_match(/would lower every value from version 3 to 1/, eedbi('migrate', path('v3.json')).err)
    end
    assert_equal [3], versions('v3.json')
  end

  def test_item_already_in_the_version_is_not_written
    before = File.read(path('v2.json'))
    eedbi('migrate', '--encrypt-version', '2', path('v2.json'))
    assert_equal before, File.read(path('v2.json'))
  end

  def test_missing_secret_is_reported_once
    with_env('ENCRYPTED_DATA_BAG_SECRET' => path('no_such_secret')) do
      r = eedbi('migrate', path('v1.json'), path('v2.json'), secret: false)
      assert_equal 1, r.status
      assert_equal 1, r.err.lines.size, r.err
      assert_match(/Secret file not found/, r.err)
    end
  end

  def test_item_without_values
    File.write(path('empty.json'), %({\n  "id": "empty"\n}\n))
    before = File.read(path('empty.json'))
    assert_equal report('empty.json', 'no values to convert'), eedbi('migrate', path('empty.json')).out
    assert_equal before, File.read(path('empty.json'))
  end

  # check fails such items, so writing them again would only hide that.
  def test_invalid_items_are_refused
    File.write(path('noid.json'), JSON.generate(read_json('v1.json').except('id')))
    File.write(path('badid.json'), JSON.generate(read_json('v1.json').merge('id' => 'bad id')))
    r = eedbi('migrate', path('noid.json'), path('badid.json'), '--dry-run')
    assert_equal 1, r.status
    assert_match(/^.*noid\.json: data bag item is missing an 'id'$/, r.err)
    assert_match(/^.*badid\.json: invalid data bag item id "bad id"/, r.err)
    assert_match(/Nothing was written \(2 of 2 items failed\)/, r.err)
  end

  # One item that cannot be converted must not leave the rest half done.
  def test_nothing_is_written_when_any_item_fails
    before = File.read(path('v1.json'))
    r = eedbi('migrate', '--encrypt-version', '3', path('v1.json'), path('wrong_key.json'), path('missing.json'))
    assert_equal 1, r.status
    assert_match(/wrong_key\.json: unable to decrypt/, r.err)
    assert_match(/missing\.json: file not found/, r.err)
    assert_match(/Nothing was written \(2 of 3 items failed\)/, r.err)
    assert_equal before, File.read(path('v1.json'))
  end

  # Once items are being written, a failure is about that one file, so the
  # others are still written, and running the command again finishes.
  def test_a_failed_write_does_not_stop_the_others
    names = %w[v1 v3 v2 mixed].map { |name| path("#{name}.json") }
    r = eedbi('migrate', *names, stdout: stdout_changing(path('v2.json')))
    assert_equal 1, r.status
    assert_equal [report('v1.json', 'converted version 1 -> 3'), report('v3.json', 'already version 3'),
                  report('mixed.json', 'converted version 0, 1, 2, 3 -> 3')].join, r.out
    assert_equal "#{path('v2.json')} changed on disk while eedbi was running; not written\n" \
                 "1 of 4 items was not written. Run the same command again to finish.\n", r.err
    assert_equal [2], versions('v2.json')

    r = eedbi('migrate', *names)
    assert_equal 0, r.status, r.err
    assert_equal report('v2.json', 'converted version 2 -> 3'), r.out.lines[2]
    assert_equal [3], versions('v2.json')
  end

  # The item written before the output failed is not reported as unwritten.
  def test_closed_output_pipe_stops_quietly
    r = eedbi('migrate', path('v1.json'), path('v2.json'), stdout: stdout_closed)
    assert_equal [141, ''], [r.status, r.err]
    assert_equal [[3], [2]], [versions('v1.json'), versions('v2.json')]

    r = eedbi('migrate', path('v1.json'), path('v2.json'))
    assert_equal [report('v1.json', 'already version 3'), report('v2.json', 'converted version 2 -> 3')].join, r.out
  end

  def test_dry_run
    before = File.read(path('v1.json'))
    r = eedbi('migrate', '--encrypt-version', '3', path('v1.json'), '--dry-run')
    assert_match(/v1\.json: would convert version 1 -> 3/, r.out)
    assert_match(/Dry run: nothing was written/, r.out)
    assert_equal before, File.read(path('v1.json'))
  end

  def test_reencrypt_is_gone
    assert_match(/invalid option: --reencrypt/, eedbi('migrate', '--reencrypt', path('v1.json')).err)
  end

  # Overlapping globs name an item twice. Writing it twice would find it
  # changed on disk the second time and stop with other items unwritten.
  def test_an_item_named_twice_is_converted_once
    r = Dir.chdir(@dir) { eedbi('migrate', 'v1.json', './v1.json', path('v1.json'), 'v2.json') }
    assert_equal 0, r.status, r.err
    assert_equal ["v1.json: converted version 1 -> 3\n", "v2.json: converted version 2 -> 3\n"], r.out.lines
    assert_equal [3], versions('v2.json')
  end
end
