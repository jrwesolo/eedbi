# frozen_string_literal: true

require_relative '../test_helper'

class ReadTest < Minitest::Test
  include EedbiTestHelper

  def test_prints_decrypted_item
    r = eedbi('read', path('v3.json'))
    assert_equal 0, r.status, r.err
    assert_equal plain('v3'), JSON.parse(r.out)
  end

  # Several keys would print values back to back, with nothing to tell
  # where one ends.
  def test_takes_one_item_and_one_key
    r = eedbi('read', path('v3.json'), 'password', 'port')
    assert_equal 2, r.status
    assert_match(/takes ITEM and an optional KEY \(received 3 arguments\)/, r.err)
    assert_match(/invalid option: --key/, eedbi('read', path('v3.json'), '--key', 'password').err)
    assert_match(/invalid option: --keys/, eedbi('read', path('v3.json'), '--keys').err)
  end

  # Like set and unset, a key that looks like an option goes after --.
  def test_key_that_starts_with_a_dash
    with_env('ENCRYPTED_DATA_BAG_SECRET' => path('encrypted_data_bag_secret')) do
      r = eedbi('set', path('v3.json'), '--', '-weird', stdin: 'x', interactive: false, secret: false)
      assert_equal 0, r.status, r.err
      assert_equal 2, eedbi('read', path('v3.json'), '-weird', secret: false).status
      assert_equal "x\n", eedbi('read', path('v3.json'), '--', '-weird', secret: false).out
    end
  end

  def test_key_prints_strings_raw_and_the_rest_as_json
    show = ->(key) { eedbi('read', path('v3.json'), key).out }
    assert_equal "Grüße, 東京, 𝄞\n", show.call('unicode')
    assert_equal "\n", show.call('empty')
    assert_equal "5432\n", show.call('port')
    assert_equal "null\n", show.call('none')
    assert_equal({ 'user' => 'admin', 'roles' => %w[read write] }, JSON.parse(show.call('nested')))
  end

  # One newline after every string, as jq -r does, and set removes one, so
  # values pass through a pipe unchanged.
  def test_strings_round_trip_through_set
    values = { 'bare' => 'abc', 'newline' => "abc\n", 'two' => "abc\n\n", 'crlf' => "abc\r\n" }
    values.each do |key, value|
      eedbi('set', path('v3.json'), key, '--from-file', '-', stdin: value, interactive: false)
    end
    assert_equal "abc\n\n", eedbi('read', path('v3.json'), 'newline').out
    values.each_key do |key|
      out = eedbi('read', path('v3.json'), key).out
      eedbi('set', path('v3.json'), "#{key}_copy", stdin: out, interactive: false)
    end
    values.each { |key, value| assert_equal value, decrypt('v3.json')["#{key}_copy"], key }
  end

  def test_digest_shows_no_plaintext
    r = eedbi('read', '--digest', path('v3.json'))
    assert_equal 0, r.status, r.err
    digests = JSON.parse(r.out)
    assert_equal 'v3', digests['id']
    assert(digests.except('id').values.all? { |digest| digest.match?(/\Ahmac:\h{16}\z/) })
    refute_includes r.out, 'hunter2'
    assert_equal "#{digests['password']}\n", eedbi('read', '--digest', path('v3.json'), 'password').out
    assert_equal "v3\n", eedbi('read', path('v3.json'), 'id', '--digest').out, 'the id is not a secret'
  end

  # The same value gives the same digest in every version and item; a
  # different secret, value or type gives another.
  def test_digest_compares_values
    digests = %w[v0 v1 v2 v3].map { |name| eedbi('read', '--digest', path("#{name}.json"), 'password').out }
    assert_equal 1, digests.uniq.size
    eedbi('set', path('v3.json'), 'port_string', stdin: '5432', interactive: false)
    port, string = %w[port port_string].map { |key| eedbi('read', '--digest', path('v3.json'), key).out }
    refute_equal port, string, '5432 and "5432" differ'

    eedbi('rekey', path('v1.json'), '--new-secret-file', path('other_secret'))
    other = eedbi('read', '--digest', path('v1.json'), 'password', '-s', path('other_secret'), secret: false).out
    refute_equal digests.first, other
  end

  # Agents and CI can turn off plaintext output; digests still work.
  def test_no_plaintext_allows_only_digests
    with_env('EEDBI_NO_PLAINTEXT' => '1') do
      [[], ['password']].each do |key|
        r = eedbi('read', path('v3.json'), *key)
        assert_equal 1, r.status
        assert_equal '', r.out
        assert_match(/eedbi read shows plaintext, which \$EEDBI_NO_PLAINTEXT disables\. .*--digest/, r.err)
      end
      assert_equal 0, eedbi('read', path('v3.json'), '--digest').status
    end
    with_env('EEDBI_NO_PLAINTEXT' => '') do
      assert_equal 0, eedbi('read', path('v3.json')).status, 'empty counts as unset'
    end
  end

  def test_missing_key
    r = eedbi('read', path('v3.json'), 'nope')
    assert_equal 1, r.status
    assert_match(/v3\.json: no key "nope"/, r.err)
  end

  def test_missing_file
    r = eedbi('read', path('missing.json'))
    assert_equal 1, r.status
    assert_match(/missing\.json: file not found/, r.err)
  end

  def test_wrong_secret
    r = eedbi('read', path('v3.json'), '-s', path('other_secret'), secret: false)
    assert_equal 1, r.status
    assert_match(/v3\.json: unable to decrypt \("password": decryption failed\)\. Is this the right secret\?/, r.err)
  end

  def test_unencrypted_item
    r = eedbi('read', path('plain.json'))
    assert_equal 1, r.status
    assert_match(/Is the item encrypted\?/, r.err)
  end

  def test_unparseable_item
    File.write(path('broken.json'), '{')
    assert_match(/broken\.json: unable to parse JSON/, eedbi('read', path('broken.json')).err)
  end

  def test_item_from_stdin
    r = eedbi('read', '-', 'password', stdin: File.read(path('v3.json')), interactive: false)
    assert_equal "hunter2\n", r.out, r.err
  end

  def test_item_from_stdin_rules
    assert_match(/stdin is a terminal/, eedbi('read', '-', interactive: true).err)
    assert_match(/Only one item can come from stdin/, eedbi('check', '-', '-', interactive: false).err)
    assert_match(/Only read, list and check can read the item from stdin/, eedbi('edit', '-', interactive: true).err)
    # write, import and set read stdin themselves; ITEM is the file they write.
    assert_equal "eedbi write reads stdin without -; ITEM is the file it writes: eedbi write ITEM < plain.json\n",
                 eedbi('write', '-', interactive: false).err
    assert_match(/eedbi import ITEM < item\.json/, eedbi('import', '-', interactive: false, secret: false).err)
    assert_match(/eedbi set ITEM KEY < value\.txt/, eedbi('set', '-', 'k', interactive: false).err)
    assert_match(/no key "-"/, eedbi('read', path('v3.json'), '-', interactive: true).err, 'a key named - is a key')
  end
end
