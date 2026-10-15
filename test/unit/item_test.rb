# frozen_string_literal: true

require_relative '../test_helper'

# Eedbi::Item: whole-item encryption rules.
class ItemTest < Minitest::Test
  SECRET = 'secret'

  def encrypted(plain, version = 3)
    Eedbi::Item.encrypt(plain, SECRET, version)
  end

  def test_id_is_never_encrypted
    item = encrypted({ 'id' => 'x', 'a' => 1 })
    assert_equal 'x', item['id']
    assert_kind_of Hash, item['a']
  end

  def test_null_value_is_encrypted
    item = encrypted({ 'id' => 'x', 'none' => nil })
    assert_kind_of Hash, item['none']
    assert_nil Eedbi::Item.decrypt(item, SECRET)['none']
  end

  def test_unchanged_values_keep_their_ciphertext
    before_plain = { 'id' => 'x', 'a' => 1, 'b' => 2 }
    before = encrypted(before_plain)
    after = Eedbi::Item.encrypt(before_plain.merge('b' => 3), SECRET, 3,
                                before_plain: before_plain, before_encrypted: before)
    assert_equal before['a'], after['a']
    refute_equal before['b'], after['b']
  end

  def test_unchanged_value_in_another_version_is_reencrypted
    before_plain = { 'id' => 'x', 'a' => 1 }
    before = encrypted(before_plain, 1)
    after = Eedbi::Item.encrypt(before_plain, SECRET, 3, before_plain: before_plain, before_encrypted: before)
    assert_equal 3, after['a']['version']
  end

  # 1 and 1.0 are equal in Ruby but not the same JSON.
  def test_integer_to_float_counts_as_a_change
    before_plain = { 'id' => 'x', 'a' => 1 }
    before = encrypted(before_plain)
    after = Eedbi::Item.encrypt({ 'id' => 'x', 'a' => 1.0 }, SECRET, 3,
                                before_plain: before_plain, before_encrypted: before)
    refute_equal before['a'], after['a']
  end

  def test_rekey_keeps_each_values_version
    plain = { 'a' => 1, 'id' => 'x', 'b' => 'two' }
    before = encrypted(plain, 1).merge('b' => Eedbi::Crypto.encrypt('two', SECRET, 3))
    after = Eedbi::Item.rekey(plain, before, 'new secret')
    assert_equal %w[id a b], after.keys
    assert_equal [1, 3], [after['a']['version'], after['b']['version']]
    assert_equal Eedbi::Item.id_first(plain), Eedbi::Item.decrypt(after, 'new secret')
  end

  def update(before_plain, before, after_plain, **options)
    Eedbi::Item.update(after_plain, SECRET, before_plain: before_plain, before_encrypted: before, **options)
  end

  def test_update_keeps_unchanged_values_whatever_their_version
    before_plain = { 'id' => 'x', 'a' => 1, 'b' => 2 }
    before = encrypted(before_plain, 1)
    after = update(before_plain, before, before_plain.merge('b' => 3, 'c' => 4), requested: 3)
    assert_equal before['a'], after['a']
    assert_equal [3, 3], [after['b']['version'], after['c']['version']]
  end

  def test_update_versions
    before_plain = { 'id' => 'x', 'a' => 1, 'b' => 2 }
    before = encrypted(before_plain, 1).merge('b' => Eedbi::Crypto.encrypt(2, SECRET, 2))
    after = update(before_plain, before, { 'id' => 'x', 'a' => 0, 'b' => 0, 'c' => 0 })
    assert_equal [1, 2, 2], %w[a b c].map { |key| after[key]['version'] }, 'own versions; new keys the highest'

    v0 = { 'id' => 'x', 'a' => 'AAAAAAAAAAAAAAAAAAAAAA==' }
    after = update({ 'id' => 'x', 'a' => 'old' }, v0, { 'id' => 'x', 'a' => 'new', 'b' => 1 }, default: 2)
    assert_equal [2, 2], %w[a b].map { |key| after[key]['version'] }, 'version 0 cannot be written'

    mixed = v0.merge('b' => Eedbi::Crypto.encrypt(1, SECRET, 1))
    after = update({ 'id' => 'x', 'a' => 'old', 'b' => 1 }, mixed, { 'id' => 'x', 'a' => 'new', 'b' => 1 }, default: 3)
    assert_equal 1, after['a']['version'], "the item's highest version, which its readers can read"
    assert_equal 2, update({}, {}, { 'id' => 'x', 'a' => 1 }, default: 2)['a']['version'], 'new item'
  end

  def test_validate
    Eedbi::Item.validate!({ 'id' => 'a.b-c_1' })
    [[], {}, { 'id' => '' }, { 'id' => 'a b' }, { 'id' => 'a/b' }, { 'id' => 1 }].each do |item|
      assert_raises(Eedbi::Error, item.inspect) { Eedbi::Item.validate!(item) }
    end
  end

  def test_decrypt_error_names_the_key
    item = encrypted({ 'id' => 'x', 'password' => 'p' })
    error = assert_raises(Eedbi::DecryptionError) { Eedbi::Item.decrypt(item, 'wrong') }
    assert_equal '"password": decryption failed', error.message
  end

  def test_unencrypted_value_is_reported
    error = assert_raises(Eedbi::NotEncryptedError) { Eedbi::Item.decrypt({ 'id' => 'x', 'a' => 1 }, SECRET) }
    assert_equal '"a": value is not encrypted', error.message
  end

  def test_decrypt_minimum
    item = encrypted({ 'id' => 'x', 'a' => 1 }, 1)
    assert_equal 1, Eedbi::Item.decrypt(item, SECRET, minimum: 1)['a']
    error = assert_raises(Eedbi::BelowMinimumError) { Eedbi::Item.decrypt(item, SECRET, minimum: 2) }
    assert_equal '"a": encryption version 1 is below the minimum 2', error.message
  end

  # A hand-edited "version": "3" must give a clean error, not a crash.
  def test_decrypt_minimum_with_a_non_integer_version
    item = encrypted({ 'id' => 'x', 'a' => 1 })
    item['a']['version'] = '3'
    assert_raises(Eedbi::Error) { Eedbi::Item.decrypt(item, SECRET, minimum: 2) }
  end

  # Decrypts fine, but holds what JSON cannot: found by test/cli/fuzz_test.rb,
  # where printing or saving such a value raised JSON::GeneratorError.
  def test_value_json_cannot_hold_is_refused
    ["{\"json_wrapper\":\"\xFF\"}", '{"json_wrapper":1e400}'].each do |payload|
      cipher = OpenSSL::Cipher.new('aes-256-gcm').encrypt
      cipher.key = OpenSSL::Digest.digest('SHA256', SECRET)
      iv = cipher.random_iv
      cipher.auth_data = ''
      data = [cipher.update(payload.b) + cipher.final].pack('m')
      field = { 'encrypted_data' => data, 'iv' => [iv].pack('m'), 'auth_tag' => [cipher.auth_tag].pack('m'),
                'version' => 3, 'cipher' => 'aes-256-gcm' }
      error = assert_raises(Eedbi::Error, payload) { Eedbi::Item.decrypt({ 'id' => 'x', 'a' => field }, SECRET) }
      assert_equal '"a": the decrypted value is not valid JSON (invalid UTF-8, or a number JSON cannot hold)',
                   error.message
    end
  end
end
