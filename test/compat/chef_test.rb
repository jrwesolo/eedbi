# frozen_string_literal: true

require_relative '../test_helper'

begin
  require 'chef/encrypted_data_bag_item'
rescue LoadError => e
  warn "Skipping #{File.basename(__FILE__)}: #{e.message}"
  return
end

# Compatibility with Chef's own implementation, in both directions, at run
# time. test/unit/fixtures_test.rb covers Chef's output from the fixtures on
# every platform; this needs the chef (or cinc) gem.
class ChefCompatTest < Minitest::Test
  include EedbiTestHelper

  PLAIN = { 'id' => 'compat', 'str' => 'café', 'num' => 42, 'list' => [1, 'a'], 'map' => { 'k' => nil } }.freeze

  def chef_decrypt(name)
    Chef::EncryptedDataBagItem.new(read_json(name), secret).to_hash
  end

  [1, 2, 3].each do |version|
    define_method("test_eedbi_decrypts_chef_v#{version}") do
      Chef::Config[:data_bag_encrypt_version] = version
      File.write(path('compat.json'), JSON.generate(Chef::EncryptedDataBagItem.encrypt_data_bag_item(PLAIN, secret)))
      assert_equal PLAIN, decrypt('compat.json')
    end

    define_method("test_chef_decrypts_eedbi_v#{version}") do
      r = with_env('EEDBI_DEFAULT_ENCRYPT_VERSION' => version.to_s) do
        eedbi('write', path('compat.json'), stdin: JSON.generate(PLAIN), interactive: false)
      end
      assert_equal 0, r.status, r.err
      assert_equal PLAIN, chef_decrypt('compat.json')
    end
  end

  %w[v0 v1 v2 v3 mixed].each do |name|
    define_method("test_chef_decrypts_the_#{name}_fixture") do
      assert_equal plain(name), chef_decrypt("#{name}.json")
    end
  end

  def test_chef_decrypts_items_eedbi_migrated_and_rekeyed
    eedbi('migrate', '--encrypt-version', '2', '--allow-downgrade', path('mixed.json'))
    assert_equal plain('mixed'), chef_decrypt('mixed.json')

    eedbi('rekey', path('mixed.json'), '--new-secret-file', path('other_secret'))
    rekeyed = Chef::EncryptedDataBagItem.new(read_json('mixed.json'), secret('other_secret')).to_hash
    assert_equal plain('mixed'), rekeyed
  end

  # The key name is not part of the ciphertext in any version, so a renamed
  # value still decrypts.
  def test_chef_decrypts_items_eedbi_renamed
    %w[v0 v1 v2 v3].each do |name|
      eedbi('rename', path("#{name}.json"), 'port', 'db_port', secret: false)
      assert_equal 5432, chef_decrypt("#{name}.json")['db_port'], name
    end
  end
end
