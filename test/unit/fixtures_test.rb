# frozen_string_literal: true

require_relative '../test_helper'

# The Chef-generated fixtures, read in-process. Needs neither Chef nor a PTY,
# so every platform checks eedbi against Chef's output for all versions.
class FixturesTest < Minitest::Test
  include EedbiTestHelper

  def item(name)
    JSON.parse(File.read(path("#{name}.json")))
  end

  %w[v0 v1 v2 v3 mixed].each do |name|
    define_method("test_#{name}_decrypts_to_plain") do
      assert_equal plain(name), Eedbi::Item.decrypt(item(name), secret)
    end
  end

  # The fixtures use fixed IVs, so encrypting the same value with the same IV
  # must give exactly the bytes Chef wrote, key order included.
  %w[v1 v2 v3].each do |name|
    define_method("test_#{name}_encryption_matches_chef_byte_for_byte") do
      plain = plain(name)
      item(name).except('id').each do |key, field|
        iv = Eedbi::Crypto.decode64(field['iv'])
        actual = Eedbi::Crypto.encrypt(plain[key], secret, field['version'], iv: iv)
        assert_equal field.to_a, actual.to_a, "#{name}.json #{key}"
      end
    end
  end

  def test_each_fixture_uses_its_format_version
    { 'v0' => [0], 'v1' => [1], 'v2' => [2], 'v3' => [3], 'mixed' => [0, 1, 2, 3] }.each do |name, expected|
      versions = item(name).except('id').values.map { |field| Eedbi::Crypto.version_of(field) }.uniq.sort
      assert_equal expected, versions, name
      assert_equal expected.max, Eedbi::Item.version_of(item(name)), name
    end
  end

  def test_wrong_key_fixture_needs_the_other_secret
    assert_raises(Eedbi::DecryptionError) { Eedbi::Item.decrypt(item('wrong_key'), secret) }
    other = File.read(path('other_secret')).strip
    assert_equal plain('wrong_key'), Eedbi::Item.decrypt(item('wrong_key'), other)
  end

  def test_tampered_v3_auth_tag_is_rejected
    tampered = item('v3')
    tampered['password']['auth_tag'] = [OpenSSL::Random.random_bytes(16)].pack('m')
    error = assert_raises(Eedbi::DecryptionError) { Eedbi::Item.decrypt(tampered, secret) }
    assert_equal '"password": decryption failed', error.message
  end

  def test_tampered_v2_hmac_is_rejected
    tampered = item('v2')
    tampered['password']['hmac'] = [OpenSSL::Random.random_bytes(32)].pack('m')
    error = assert_raises(Eedbi::DecryptionError) { Eedbi::Item.decrypt(tampered, secret) }
    assert_equal '"password": invalid hmac', error.message
  end

  def test_v0_with_the_wrong_secret_fails
    assert_raises(Eedbi::DecryptionError) { Eedbi::Item.decrypt(item('v0'), secret('other_secret')) }
  end

  def test_plain_fixture_is_not_encrypted
    assert_raises(Eedbi::NotEncryptedError) { Eedbi::Item.decrypt(item('plain'), secret) }
  end
end
