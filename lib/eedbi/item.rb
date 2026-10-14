# frozen_string_literal: true

module Eedbi
  # Encryption of a whole data bag item. The id is never encrypted.
  module Item
    module_function

    # Values below `minimum` are refused, like Chef's
    # data_bag_decrypt_minimum_version: an attacker who can edit the file
    # could otherwise swap in a value in a version without integrity checks.
    def decrypt(item, secret, minimum: 0)
      item.each_with_object({}) do |(key, value), plain|
        plain[key] = key == 'id' ? value : decrypt_field(key, value, secret, minimum)
      end
    end

    # Every value in `version`. Unchanged values already in that version keep
    # their ciphertext, which keeps diffs small. For new items and migrate.
    #
    # The id is always written first, wherever it was in `plain`.
    def encrypt(plain, secret, version, before_plain: {}, before_encrypted: {})
      id_first(plain).each_with_object({}) do |(key, value), encrypted|
        old = before_encrypted[key]
        encrypted[key] = if key == 'id'
                           value
                         elsif before_plain.key?(key) && value.eql?(before_plain[key]) &&
                               Crypto.version_of(old) == version
                           old
                         else
                           Crypto.encrypt(value, secret, version)
                         end
      end
    end

    # For edit, set and write, which never convert what they do not change:
    #
    # - unchanged values keep their ciphertext, whatever their version
    # - changed values keep their version, or take `requested`
    # - new keys, and changed version 0 values (version 0 cannot be
    #   written), take `requested`, else the item's highest version, which
    #   everything that reads the item can already read, else `default`
    def update(plain, secret, before_plain:, before_encrypted:, requested: nil, default: Crypto::DEFAULT_VERSION)
      fallback = writable(version_of(before_encrypted)) || default
      id_first(plain).each_with_object({}) do |(key, value), encrypted|
        old = before_encrypted[key]
        encrypted[key] = if key == 'id'
                           value
                         elsif old && before_plain.key?(key) && value.eql?(before_plain[key])
                           old
                         else
                           Crypto.encrypt(value, secret, requested || writable(Crypto.version_of(old)) || fallback)
                         end
      end
    end

    def writable(version)
      version if Crypto::ENCRYPT_VERSIONS.include?(version)
    end

    # Every value encrypted again with `secret`, each in the version it is
    # stored in now. For rekey, which changes the secret and nothing else.
    def rekey(plain, before_encrypted, secret)
      id_first(plain).to_h do |key, value|
        [key, key == 'id' ? value : Crypto.encrypt(value, secret, Crypto.version_of(before_encrypted[key]))]
      end
    end

    # `item` with its id moved to the front. Chef does not care about key
    # order, but a fixed place for the id keeps files consistent.
    def id_first(item)
      return item unless item.key?('id')

      { 'id' => item['id'] }.merge(item.except('id'))
    end

    # Highest encryption version present in an encrypted item, or nil.
    def version_of(item)
      item.except('id').values.map { |field| Crypto.version_of(field) }.compact.max
    end

    DIGEST_CONTEXT = 'eedbi value digest v1'

    # A value's fingerprint, for comparing values without showing them. It
    # is an HMAC with a key derived from the secret, so without the secret
    # it can be neither reversed nor guessed, not even for a short password.
    # Equal values give equal digests under one secret, whatever their
    # encryption version, key or item. The JSON form tells "5" from 5.
    def digest(value, secret)
      key = OpenSSL::HMAC.digest('SHA256', secret, DIGEST_CONTEXT)
      "hmac:#{OpenSSL::HMAC.hexdigest('SHA256', key, JSON.generate(value))[0, 16]}"
    end

    # Keys whose value is not encrypted, in any version.
    def unencrypted_keys(item)
      item.except('id').reject { |_, field| Crypto.version_of(field) }.keys
    end

    # Keys whose value is in version 0, which can only be read, and which
    # plaintext can pass for without the secret.
    def version_0_keys(item)
      item.except('id').select { |_, field| Crypto.version_of(field).eql?(0) }.keys
    end

    # Checks, without the secret, that every encrypted value in versions 1
    # to 3 has a known version and the cipher that goes with it.
    def check_fields!(item)
      item.except('id').each do |key, field|
        Crypto.checked_version(field) if field.is_a?(Hash)
      rescue Error => e
        raise Error, "#{Eedbi.quote_key(key)}: #{e.message}"
      end
    end

    # Whether every value is shaped exactly like Chef's encrypted values in
    # versions 1 to 3, as when an encrypted item is given where plaintext
    # is expected.
    def looks_encrypted?(values)
      !values.empty? && values.all? { |field| field.is_a?(Hash) && field.key?('iv') && valid_field?(field) }
    end

    # A version 1 to 3 field whose version and cipher match.
    def valid_field?(field)
      Crypto.checked_version(field)
      true
    rescue Error
      false
    end

    def validate!(item)
      raise Error, 'Data bag item must be a JSON object' unless item.is_a?(Hash)
      raise Error, "Data bag item is missing an 'id'" unless item.key?('id')
      return if item['id'].is_a?(String) && item['id'].match?(VALID_ID)

      raise Error, "Invalid data bag item id #{item['id'].inspect} (allowed: letters, numbers, '.', '-', '_')"
    end

    def decrypt_field(key, value, secret, minimum)
      version = Crypto.version_of(value)
      if version.is_a?(Integer) && version < minimum
        raise BelowMinimumError, "encryption version #{version} is below the minimum #{minimum}"
      end

      json_value!(Crypto.decrypt(value, secret))
    rescue Error => e
      raise e.class, "#{Eedbi.quote_key(key)}: #{e.message}"
    end

    # A decrypted value that JSON cannot hold, such as invalid UTF-8 or a
    # number too large for a float, which neither eedbi nor Chef writes.
    # Printing or saving it would otherwise fail with a Ruby exception.
    def json_value!(value)
      JSON.generate(value)
      value
    rescue JSON::GeneratorError, EncodingError
      raise Error, 'the decrypted value is not valid JSON (invalid UTF-8, or a number JSON cannot hold)'
    end
  end
end
