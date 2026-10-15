# frozen_string_literal: true

require_relative '../test_helper'

class UnsetTest < Minitest::Test
  include EedbiTestHelper

  # No secret: unset decrypts nothing.
  def unset(*args)
    eedbi('unset', *args, secret: false)
  end

  def test_removes_keys_and_keeps_other_ciphertext
    before = read_json('v3.json')
    r = unset(path('v3.json'), 'list', 'nested')
    assert_equal report('v3.json', 'removed "list", "nested"'), r.out, r.err
    assert_equal plain('v3').except('list', 'nested'), decrypt('v3.json')
    (before.keys - %w[id list nested]).each { |key| assert_equal before[key], read_json('v3.json')[key], key }
  end

  def test_missing_key_writes_nothing
    before = File.read(path('v3.json'))
    r = unset(path('v3.json'), 'list', 'nope', 'gone')
    assert_equal 1, r.status
    assert_match(/no keys "nope", "gone"/, r.err)
    assert_equal before, File.read(path('v3.json'))
  end

  def test_ignore_missing_skips_missing_keys
    r = unset(path('v3.json'), 'list', 'nope', '--ignore-missing')
    assert_equal [0, report('v3.json', 'removed "list"')], [r.status, r.out], r.err

    before = File.read(path('v3.json'))
    r = unset(path('v3.json'), 'list', 'nope', '--ignore-missing')
    assert_equal [0, report('v3.json', 'no changes')], [r.status, r.out], 'a second run'
    assert_equal before, File.read(path('v3.json'))
  end

  # The commands that decrypt refuse an item with a value committed
  # unencrypted; unset can remove it, and set can add it back encrypted.
  def test_repairs_an_item_with_an_unencrypted_value
    File.write(path('leak.json'), JSON.generate(read_json('v3.json').merge('id' => 'leak', 'token' => 'plain')))
    assert_match(/"token": value is not encrypted/, eedbi('set', path('leak.json'), 'token', stdin: 'x').err)

    assert_equal report('leak.json', 'removed "token"'), unset(path('leak.json'), 'token').out
    assert_equal 0, eedbi('set', path('leak.json'), 'token', stdin: 'plain', interactive: false).status
    assert_equal plain('leak').merge('token' => 'plain'), decrypt('leak.json')
  end

  def test_takes_no_secret
    assert_match(/invalid option: -s/, eedbi('unset', path('v3.json'), 'list').err)
  end

  def test_id_cannot_be_removed
    assert_match(/id cannot be removed/, unset(path('v3.json'), 'id').err)
  end

  def test_needs_item_and_key
    assert_match(/needs ITEM and at least one KEY/, unset(path('v3.json')).err)
  end

  def test_missing_item
    assert_match(/missing\.json: file not found/, unset(path('missing.json'), 'a').err)
  end

  def test_warns_about_an_id_that_does_not_match
    FileUtils.cp(path('v3.json'), path('copy.json'))
    r = unset(path('copy.json'), 'port')
    assert_equal [0, "Warning: id 'v3' does not match file name 'copy'\n"], [r.status, r.err]
  end

  def test_dry_run
    before = File.read(path('v3.json'))
    assert_equal report('v3.json', 'would remove "list", "nested"'),
                 unset(path('v3.json'), 'list', 'nested', '--dry-run').out
    assert_equal before, File.read(path('v3.json'))
  end
end
