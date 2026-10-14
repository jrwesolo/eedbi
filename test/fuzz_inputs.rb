# frozen_string_literal: true

# Random but repeatable broken input, for test/cli/fuzz_test.rb (eedbi
# never raises) and test/compat/fuzz_compat_test.rb (eedbi agrees with
# Chef). Included into a test with EedbiTestHelper, for path and secret.
# EEDBI_FUZZ_SEED and EEDBI_FUZZ_CASES try other cases.
module FuzzInputs
  SEED = Integer(ENV.fetch('EEDBI_FUZZ_SEED', '20261014'))
  CASES = Integer(ENV.fetch('EEDBI_FUZZ_CASES', '120'))
  BASES = %w[v0 v1 v2 v3 mixed plain].freeze

  # Plaintexts that decrypt fine with the right secret but are not what
  # eedbi writes: what a buggy or hostile writer of the file could put
  # there. Versions 1 to 3 wrap a JSON document; version 0 is YAML.
  JSON_PAYLOADS = [
    "{\"json_wrapper\":\"\xFF\"}", "{\"json_wrapper\":{\"\xFF\":1}}", '{"json_wrapper":1e400}',
    '{"json_wrapper":-1e400}', '{"json_wrapper":NaN}', '{"json_wrapper":"a","json_wrapper":"b"}', '[1]', 'null',
    '{"other":1}', '', "\xEF\xBB\xBF{\"json_wrapper\":1}", "{\"json_wrapper\":#{'[' * 200}#{']' * 200}}"
  ].map(&:b).freeze
  YAML_PAYLOADS = [
    "--- .inf\n", "--- .nan\n", "--- !!binary /w==\n", "--- 2020-01-01\n", "--- :sym\n", "--- &a [*a]\n",
    "--- !ruby/object:Object {}\n", "--- \"\\xFF\"\n", "--- 1e400\n", "--- {1: 2}\n", "--- {[1]: 2}\n",
    "--- \"\\x00\"\n", "\xFF\n", "--- [\n"
  ].map(&:b).freeze

  private

  # An item file, or what is piped in: usually a fixture with a few values
  # broken, sometimes not an object at all, sometimes broken bytes.
  def item_bytes(rng)
    item = JSON.parse(File.read(path("#{BASES.sample(random: rng)}.json")))
    rng.rand(1..3).times { mutate_item(item, rng) }
    document = rng.rand < 0.1 ? junk_value(rng, 0) : item
    text = (rng.rand < 0.5 ? JSON.pretty_generate(document) : JSON.generate(document)).b
    rng.rand < 0.3 ? mutate_bytes(text, rng) : text
  end

  def mutate_item(item, rng)
    key = item.keys.sample(random: rng) || 'id'
    case rng.rand(8)
    when 0 then item[key] = junk_value(rng, 0)
    when 1 then item[key] = mutate_field(item[key], rng)
    when 2 then item[key] = crafted_field(rng)
    when 3 then item.delete(key)
    when 4 then item['id'] = junk_value(rng, 0)
    when 5 then item[junk_string(rng)] = junk_value(rng, 0)
    when 6 then item[key] = crafted_field(rng, version: 0)
    else item.delete('id')
    end
  end

  # A real encrypted value with parts missing, of the wrong type, or wrong.
  def mutate_field(field, rng)
    return junk_string(rng) unless field.is_a?(Hash)

    field = field.dup
    case rng.rand(5)
    when 0 then field.delete(field.keys.sample(random: rng))
    when 1 then field[field.keys.sample(random: rng)] = junk_value(rng, 1)
    when 2 then field['version'] = [0, 1, 2, 3, 4, '3', 3.0, nil, -1, 2**70, [3]].sample(random: rng)
    when 3 then field['cipher'] = ['aes-256-cbc', 'aes-256-gcm', 'rot13', nil, 3, ['aes-256-cbc']].sample(random: rng)
    else
      data = field['encrypted_data'].to_s.dup
      data[rng.rand(data.size)] = 'A' unless data.empty?
      field['encrypted_data'] = data
    end
    field
  end

  # Encrypted correctly with the fixture secret, around a payload eedbi
  # would never write.
  def crafted_field(rng, version: rng.rand(1..3))
    crafted_field_for((version.zero? ? YAML_PAYLOADS : JSON_PAYLOADS).sample(random: rng), version)
  end

  def crafted_field_for(payload, version)
    key = secret
    return v0_field(payload, key) if version.zero?

    cipher = OpenSSL::Cipher.new(version == 3 ? 'aes-256-gcm' : 'aes-256-cbc').encrypt
    cipher.key = OpenSSL::Digest.digest('SHA256', key)
    iv = cipher.random_iv
    cipher.auth_data = '' if version == 3
    data = [(payload.empty? ? '' : cipher.update(payload)) + cipher.final].pack('m')
    field = { 'encrypted_data' => data }
    field['hmac'] = [OpenSSL::HMAC.digest('SHA256', key, data)].pack('m') if version == 2
    field['iv'] = [iv].pack('m')
    field['auth_tag'] = [cipher.auth_tag].pack('m') if version == 3
    field.merge('version' => version, 'cipher' => version == 3 ? 'aes-256-gcm' : 'aes-256-cbc')
  end

  def v0_field(payload, key)
    cipher = OpenSSL::Cipher.new('aes-256-cbc').encrypt
    cipher.pkcs5_keyivgen(key)
    [(payload.empty? ? '' : cipher.update(payload)) + cipher.final].pack('m')
  end

  def junk_value(rng, depth)
    choices = [nil, true, false, 0, -1, 2**70, 0.5, 1e300, '', 'hunter2', 'abcdefghijklmnopqrstuv==', "\u00fc\u{1F600}"]
    return choices.sample(random: rng) if depth > 2 || rng.rand < 0.6

    case rng.rand(3)
    when 0 then Array.new(rng.rand(3)) { junk_value(rng, depth + 1) }
    when 1 then { 'encrypted_data' => junk_value(rng, depth + 1), 'version' => junk_value(rng, depth + 1) }
    else { junk_string(rng) => junk_value(rng, depth + 1) }
    end
  end

  def junk_string(rng)
    ['', '-', 'id ', "new\nline", '"', "\u00e9", 'a' * 300, "tab\t", 'password'].sample(random: rng)
  end

  def mutate_bytes(text, rng)
    text = text.dup
    case rng.rand(7)
    when 0 then text[0, rng.rand(text.size + 1)]
    when 1 then text.tap { |t| t.setbyte(rng.rand(t.size), rng.rand(256)) unless t.empty? }
    when 2 then text.insert(rng.rand(text.size + 1), "\xFF".b)
    when 3 then "\xEF\xBB\xBF".b + text
    when 4 then "#{text}\n// comment\n{".b
    when 5 then text.sub(/\}\s*\z/, ',"big":1e400}'.b)
    else ''.b
    end
  end
end
