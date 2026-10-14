# frozen_string_literal: true

require_relative '../test_helper'

# Eedbi::Crypto on its own, without Chef, so it runs on every platform.
class CryptoTest < Minitest::Test
  SECRET = 'secret'

  def test_round_trip_for_every_encrypt_version
    Eedbi::Crypto::ENCRYPT_VERSIONS.each do |version|
      field = Eedbi::Crypto.encrypt({ 'a' => [1, nil] }, SECRET, version)
      assert_equal({ 'a' => [1, nil] }, Eedbi::Crypto.decrypt(field, SECRET), "version #{version}")
    end
  end

  def test_version_of
    secret = 'secret'
    [1, 2, 3].each { |version| assert_equal version, Eedbi::Crypto.version_of(Eedbi::Crypto.encrypt('x', secret, version)) }
    v0 = JSON.parse(File.read(File.join(EedbiTestHelper::FIXTURES, 'v0.json')))['password']
    assert_equal 0, Eedbi::Crypto.version_of(v0)
    ['hunter2', '', 'not base64!', 'abc=', 1, nil, [], { 'version' => 3 }].each do |value|
      assert_nil Eedbi::Crypto.version_of(value), value.inspect
    end
  end

  # Chef refuses a value without a cipher, so passing it would let check
  # approve an item that Chef cannot read.
  # Chef accepts only an Integer version, so check must not pass a 3.0 that
  # Ruby would otherwise take for 3.
  def test_version_must_be_an_integer
    field = Eedbi::Crypto.encrypt('hello', SECRET, 3).merge('version' => 3.0)
    error = assert_raises(Eedbi::Error) { Eedbi::Crypto.decrypt(field, SECRET) }
    assert_equal 'unsupported encryption version 3.0', error.message
  end

  def test_missing_cipher_is_rejected
    Eedbi::Crypto::ENCRYPT_VERSIONS.each do |version|
      field = Eedbi::Crypto.encrypt('hello', SECRET, version)
      [field.except('cipher'), field.merge('cipher' => nil)].each do |broken|
        error = assert_raises(Eedbi::Error, "version #{version}") { Eedbi::Crypto.decrypt(broken, SECRET) }
        assert_equal "missing cipher for encryption version #{version}", error.message
      end
    end
  end

  # OpenSSL accepts GCM tags shorter than 16 bytes. With a 1 byte tag, a
  # modified ciphertext would pass about once in 256 attempts.
  def test_truncated_v3_auth_tag_is_rejected
    field = Eedbi::Crypto.encrypt('hello', SECRET, 3)
    tag = Eedbi::Crypto.decode64(field['auth_tag'])
    [0, 1, 4, 12, 15].each do |length|
      truncated = field.merge('auth_tag' => Eedbi::Crypto.encode64(tag[0, length]))
      assert_raises(Eedbi::DecryptionError, "#{length} byte tag") { Eedbi::Crypto.decrypt(truncated, SECRET) }
    end
  end

  def test_forgery_with_short_tags_fails
    field = Eedbi::Crypto.encrypt('hello', SECRET, 3)
    ciphertext = Eedbi::Crypto.decode64(field['encrypted_data'])
    # Byte 17 of '{"json_wrapper":"hello"}' is the "h". GCM is a stream
    # cipher, so flipping ciphertext bits flips the same plaintext bits.
    ciphertext.setbyte(17, ciphertext.getbyte(17) ^ ('h'.ord ^ 'j'.ord))
    forged = (0..255).filter_map do |byte|
      attempt = field.merge('encrypted_data' => Eedbi::Crypto.encode64(ciphertext),
                            'auth_tag' => Eedbi::Crypto.encode64(byte.chr))
      Eedbi::Crypto.decrypt(attempt, SECRET)
    rescue Eedbi::DecryptionError
      nil
    end
    assert_empty forged
  end

  def test_missing_v3_auth_tag_is_rejected
    field = Eedbi::Crypto.encrypt('hello', SECRET, 3).except('auth_tag')
    assert_raises(Eedbi::DecryptionError) { Eedbi::Crypto.decrypt(field, SECRET) }
  end
end
