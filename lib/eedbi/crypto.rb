# frozen_string_literal: true

module Eedbi
  # Encryption of a single data bag item value.
  #
  # Version 0: AES-256-CBC, key and IV from OpenSSL's legacy MD5 KDF, YAML
  #            payload, stored as a bare base64 string. Decrypt only.
  # Version 1: AES-256-CBC, key = SHA256(secret), random IV.
  # Version 2: Version 1 plus HMAC-SHA256(secret, base64 ciphertext).
  # Version 3: AES-256-GCM, key = SHA256(secret), random IV, auth tag.
  #
  # Versions 1 to 3 encrypt the JSON document {"json_wrapper": value}.
  module Crypto
    CBC = 'aes-256-cbc'
    GCM = 'aes-256-gcm'
    ENCRYPT_VERSIONS = [1, 2, 3].freeze
    DECRYPT_VERSIONS = [0, 1, 2, 3].freeze
    AUTH_TAG_BYTES = 16
    # For new items, unless configured otherwise ($EEDBI_DEFAULT_ENCRYPT_VERSION).
    DEFAULT_VERSION = 3

    module_function

    # `iv` is for known-answer tests only. Reusing an IV with the same secret
    # breaks the encryption, version 3 most of all.
    def encrypt(value, secret, version, iv: nil)
      unless ENCRYPT_VERSIONS.include?(version)
        raise Error, "Invalid encryption version #{version}. Supported versions are '1', '2', '3'"
      end

      cipher = OpenSSL::Cipher.new(version == 3 ? GCM : CBC).encrypt
      cipher.key = key_for(secret)
      if iv
        cipher.iv = iv
      else
        iv = cipher.random_iv
      end
      cipher.auth_data = '' if version == 3
      data = encode64(cipher.update(JSON.generate('json_wrapper' => value)) + cipher.final)

      # Key order matches Chef's output to keep diffs familiar.
      field = { 'encrypted_data' => data }
      field['hmac'] = encode64(OpenSSL::HMAC.digest('SHA256', secret, data)) if version == 2
      field['iv'] = encode64(iv)
      field['auth_tag'] = encode64(cipher.auth_tag) if version == 3
      field.merge('version' => version, 'cipher' => version == 3 ? GCM : CBC)
    end

    def decrypt(field, secret)
      return decrypt_v0(field, secret) if field.is_a?(String)

      version = checked_version(field)
      verify_hmac!(field, secret) if version == 2
      cipher = OpenSSL::Cipher.new(version == 3 ? GCM : CBC).decrypt
      cipher.key = key_for(secret)
      cipher.iv = decode64(field['iv'])
      set_auth_tag(cipher, field) if version == 3
      unwrap(cipher.update(decode64(field['encrypted_data'])) + cipher.final)
    rescue OpenSSL::Cipher::CipherError, ArgumentError
      raise DecryptionError, 'decryption failed'
    end

    # The encryption version of an encrypted field, after checking that the
    # field is one and that its cipher matches the version. Chef refuses a
    # field without a cipher, so a missing one is an error too.
    def checked_version(field)
      raise NotEncryptedError, 'value is not encrypted' unless field.is_a?(Hash) && field.key?('encrypted_data')

      version = field['version']
      # An Integer, as Chef requires: 3.0 equals 3 in Ruby, but Chef refuses it.
      raise Error, "unsupported encryption version #{version.inspect}" unless [1, 2, 3].any? { |v| v.eql?(version) }

      algorithm = version == 3 ? GCM : CBC
      return version if field['cipher'] == algorithm
      raise Error, "missing cipher for encryption version #{version}" if field['cipher'].nil?

      raise Error, "cipher #{field['cipher'].inspect} is not valid for encryption version #{version}"
    end

    # OpenSSL accepts tags as short as one byte, which would let anyone who
    # can edit the file forge a value in a few hundred attempts.
    def set_auth_tag(cipher, field)
      tag = decode64(field['auth_tag'])
      raise DecryptionError, 'invalid auth_tag' unless tag.bytesize == AUTH_TAG_BYTES

      cipher.auth_tag = tag
      cipher.auth_data = ''
    end

    def decrypt_v0(data, secret)
      # Only version 0 needs YAML, which adds about an eighth to startup.
      # Before anything can raise, since the rescue below names Psych.
      require 'yaml'
      raise NotEncryptedError, 'value is not encrypted' unless v0_ciphertext?(data)

      bytes = decode64(data)
      cipher = OpenSSL::Cipher.new(CBC).decrypt
      cipher.pkcs5_keyivgen(secret)
      YAML.safe_load((cipher.update(bytes) + cipher.final).force_encoding(Encoding::UTF_8))
    rescue OpenSSL::Cipher::CipherError, Psych::Exception
      raise DecryptionError, 'decryption failed'
    end

    # Version of an encrypted field, or nil when it is not encrypted.
    def version_of(field)
      case field
      when String then 0 if v0_ciphertext?(field)
      when Hash then field['version'] if field.key?('encrypted_data')
      end
    end

    # Whether a string looks like a version 0 value: base64 of whole AES
    # blocks. A plaintext string can pass by chance, but most do not, so
    # they are reported as unencrypted rather than as version 0.
    def v0_ciphertext?(string)
      return false unless string.match?(%r{\A[A-Za-z0-9+/=\s]+\z})

      bytes = decode64(string)
      !bytes.empty? && (bytes.bytesize % 16).zero?
    end

    def key_for(secret)
      OpenSSL::Digest.digest('SHA256', secret)
    end

    def unwrap(json)
      parsed = JSON.parse(json.force_encoding(Encoding::UTF_8))
      raise DecryptionError, 'decryption failed' unless parsed.is_a?(Hash) && parsed.key?('json_wrapper')

      parsed['json_wrapper']
    rescue JSON::ParserError, EncodingError
      raise DecryptionError, 'decryption failed'
    end

    def verify_hmac!(field, secret)
      expected = OpenSSL::HMAC.digest('SHA256', secret, field['encrypted_data'].to_s)
      return if secure_compare(expected, decode64(field['hmac']))

      raise DecryptionError, 'invalid hmac'
    end

    def secure_compare(left, right)
      return false unless left.bytesize == right.bytesize

      left.bytes.zip(right.bytes).reduce(0) { |acc, (x, y)| acc | (x ^ y) }.zero?
    end

    # Same output as Base64.encode64 (60 character lines), without needing
    # the base64 gem, which is no longer a default gem as of Ruby 3.4.
    def encode64(bytes)
      [bytes].pack('m')
    end

    def decode64(string)
      string.to_s.unpack1('m')
    end
  end
end
