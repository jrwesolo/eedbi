# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../fuzz_inputs'

begin
  require 'chef/encrypted_data_bag_item'
  require 'chef/data_bag_item'
  require 'ffi_yajl'
rescue LoadError => e
  warn "Skipping #{File.basename(__FILE__)}: #{e.message}"
  return
end

# eedbi against the code knife and chef-client run, on the inputs of
# test/cli/fuzz_test.rb. eedbi refuses some items and values that Chef
# takes, where Chef would hand a recipe nil, ciphertext, or a value JSON
# cannot hold (README, "Differences from knife"). It must never take what
# Chef refuses, nor read a different value.
class FuzzCompatTest < Minitest::Test
  include EedbiTestHelper
  include FuzzInputs

  BOM = "\xEF\xBB\xBF".b

  def teardown
    Chef::Config.reset
    super
  end

  def test_eedbi_never_reads_what_chef_refuses
    rng = Random.new(SEED)
    (CASES * 4).times do |index|
      bytes = item_bytes(rng)
      item = eedbi_item(bytes)
      next unless item

      label = "seed #{SEED}, case #{index}: #{bytes.inspect[0, 300]}"
      # The one way eedbi reads more than knife: a leading byte order mark,
      # which eedbi check fails instead.
      knife = knife_item(bytes.delete_prefix(BOM))
      refute_nil knife, "#{label}\nknife cannot parse an item eedbi reads"
      assert_equal knife.inspect, item.inspect, "#{label}\nknife parses it differently"
      check_id(label, item)
      item.each_key { |key| check_value(label, item, key) unless key == 'id' }
    end
  end

  # Each payload eedbi would never write, in each version.
  def test_crafted_payloads
    [0, 1, 2, 3].each do |version|
      (version.zero? ? YAML_PAYLOADS : JSON_PAYLOADS).each do |payload|
        field = crafted_field_for(payload, version)
        check_value("version #{version}, #{payload.inspect[0, 80]}", { 'k' => field }, 'k')
      end
    end
  end

  # What one encrypts, the other reads back, in every version.
  def test_values_round_trip_both_ways
    rng = Random.new(SEED)
    (CASES * 4).times do
      value = junk_value(rng, 0)
      [1, 2, 3].each do |version|
        Chef::Config[:data_bag_encrypt_version] = version
        ours = Eedbi::Crypto.encrypt(value, secret, version)
        theirs = Chef::EncryptedDataBagItem::Encryptor.new(value, secret).for_encrypted_item
        label = "version #{version}, #{value.inspect[0, 120]}"
        assert_equal value.inspect, Chef::EncryptedDataBagItem::Decryptor.for(ours, secret).for_decrypted_item.inspect,
                     label
        assert_equal value.inspect, Eedbi::Crypto.decrypt(theirs, secret).inspect, label
      end
    end
  end

  private

  def eedbi_item(bytes)
    File.binwrite(path('f.json'), bytes)
    Eedbi::Store.read(path('f.json')).item
  rescue Eedbi::Error
    nil
  end

  # knife data bag from file parses with FFI_Yajl, and DataBagItem#raw_data=
  # takes only a Hash.
  def knife_item(bytes)
    item = FFI_Yajl::Parser.parse(bytes.dup.force_encoding(Encoding::UTF_8))
    item if item.is_a?(Hash)
  rescue FFI_Yajl::ParseError
    nil
  end

  def check_id(label, item)
    Eedbi::Item.validate!(item)
  rescue Eedbi::Error
    nil
  else
    begin
      Chef::DataBagItem.validate_id!(item['id'])
    rescue StandardError => e
      flunk "#{label}\nChef refuses an id eedbi takes: #{e.message}"
    end
  end

  # What EncryptedDataBagItem.load returns for the key, whatever the rest of
  # the item looks like.
  def check_value(label, item, key)
    ours = Eedbi::Item.decrypt({ key => item[key] }, secret)[key]
  rescue Eedbi::Error
    nil
  else
    theirs = begin
      Chef::EncryptedDataBagItem.new(item, secret)[key]
    rescue StandardError => e
      flunk "#{label}\nkey #{key.inspect}: Chef refuses a value eedbi reads: #{e.class}: #{e.message}"
    end
    assert_equal theirs.inspect, ours.inspect, "#{label}\nkey #{key.inspect}: Chef reads another value"
  end
end
