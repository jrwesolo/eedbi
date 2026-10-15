# frozen_string_literal: true

# Regenerates the encrypted fixtures from plain.json with Chef's own
# implementation, so that the tests compare eedbi against Chef rather than
# against itself. Needs the chef (or cinc) gem:
#
#   ruby test/fixtures/generate.rb          # rewrite the fixtures
#   ruby test/fixtures/generate.rb --check  # fail if any fixture is stale
#
# IVs are derived from the item and key names instead of being random, so the
# output is reproducible and every field doubles as a known-answer test
# vector. Never do this outside of test fixtures: reusing an IV with the same
# secret breaks the encryption.

require 'chef/encrypted_data_bag_item'
require 'json'
require 'openssl'
require 'yaml'

DIR = __dir__
SECRET = File.read(File.join(DIR, 'encrypted_data_bag_secret')).strip
OTHER_SECRET = File.read(File.join(DIR, 'other_secret')).strip
PLAIN = JSON.parse(File.read(File.join(DIR, 'plain.json')))

def iv_for(item, key, version)
  OpenSSL::Digest.digest('SHA256', "#{item}/#{key}")[0, version == 3 ? 12 : 16]
end

# Chef 0.10 wrote version 0 and no current Chef can, so it is rebuilt here
# from that release's algorithm. Chef's version 0 decryptor checks it below.
def encrypt_v0(value, secret)
  cipher = OpenSSL::Cipher.new('aes-256-cbc').encrypt
  cipher.pkcs5_keyivgen(secret)
  [cipher.update(value.to_yaml) + cipher.final].pack('m')
end

def encrypt(item, key, value, version, secret)
  return encrypt_v0(value, secret) if version.zero?

  Chef::Config[:data_bag_encrypt_version] = version
  iv = [iv_for(item, key, version)].pack('m')
  Chef::EncryptedDataBagItem::Encryptor.new(value, secret, iv).for_encrypted_item
end

# Builds an item named `name` from plain.json. `versions` gives the format
# version for each value, cycling through the list.
def build(name, versions, secret = SECRET)
  values = PLAIN.except('id').each_with_index.to_h do |(key, value), index|
    [key, encrypt(name, key, value, versions[index % versions.size], secret)]
  end
  item = { 'id' => name }.merge(values)

  decrypted = Chef::EncryptedDataBagItem.new(item, secret).to_hash
  raise "#{name}: Chef does not decrypt it back to plain.json" unless decrypted == PLAIN.merge('id' => name)

  "#{JSON.pretty_generate(item)}\n"
end

FIXTURES = {
  'v0.json' => build('v0', [0]),
  'v1.json' => build('v1', [1]),
  'v2.json' => build('v2', [2]),
  'v3.json' => build('v3', [3]),
  'mixed.json' => build('mixed', [0, 1, 2, 3]),
  'wrong_key.json' => build('wrong_key', [3], OTHER_SECRET)
}.freeze

if ARGV.include?('--check')
  stale = FIXTURES.keys.reject do |file|
    target = File.join(DIR, file)
    File.exist?(target) && File.read(target) == FIXTURES[file]
  end
  abort "Stale fixtures, run ruby test/fixtures/generate.rb: #{stale.join(', ')}" if stale.any?
  puts 'Fixtures are up to date'
else
  FIXTURES.each { |file, content| File.write(File.join(DIR, file), content) }
  puts "Wrote #{FIXTURES.keys.join(', ')}"
end
