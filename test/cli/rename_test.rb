# frozen_string_literal: true

require_relative '../test_helper'

class RenameTest < Minitest::Test
  include EedbiTestHelper

  # Every version, including 0, whose values cannot be written any more.
  %w[v0 v1 v2 v3 mixed].each do |name|
    define_method("test_keeps_the_ciphertext_and_position_in_#{name}") do
      before = read_json("#{name}.json")
      r = eedbi('rename', path("#{name}.json"), 'port', 'db_port', secret: false)
      assert_equal report("#{name}.json", 'renamed "port" to "db_port"'), r.out, r.err

      after = read_json("#{name}.json")
      assert_equal before.keys.map { |key| key == 'port' ? 'db_port' : key }, after.keys
      assert_equal before['port'], after['db_port']
      expected = plain(name).to_h { |key, value| [key == 'port' ? 'db_port' : key, value] }
      assert_equal expected, decrypt("#{name}.json")
    end
  end

  def test_moves_the_id_first
    File.write(path('late.json'), JSON.generate('a' => read_json('v3.json')['port'], 'id' => 'late'))
    eedbi('rename', path('late.json'), 'a', 'b', secret: false)
    assert_equal %w[id b], read_json('late.json').keys
  end

  def test_refuses_missing_and_existing_keys
    before = File.read(path('v3.json'))
    r = eedbi('rename', path('v3.json'), 'nope', 'other', secret: false)
    assert_equal 1, r.status
    assert_match(/v3\.json: no key "nope"/, r.err)
    r = eedbi('rename', path('v3.json'), 'port', 'list', secret: false)
    assert_match(/v3\.json: key "list" already exists/, r.err)
    assert_equal before, File.read(path('v3.json'))
  end

  def test_usage_errors
    [%w[id other], %w[port id], %w[port port]].each do |old, new|
      assert_equal 2, eedbi('rename', path('v3.json'), old, new, secret: false).status, "#{old} -> #{new}"
    end
    r = eedbi('rename', path('v3.json'), 'port', secret: false)
    assert_equal 2, r.status
    assert_match(/needs ITEM, OLD and NEW \(received 2 arguments\)/, r.err)
    assert_match(/invalid option: -s/, eedbi('rename', path('v3.json'), 'a', 'b').err)
  end

  # As for unset: the rename is written, but knife upload would reject it.
  def test_warns_about_an_id_that_does_not_match
    FileUtils.cp(path('v3.json'), path('copy.json'))
    r = eedbi('rename', path('copy.json'), 'port', 'p', secret: false)
    assert_equal [0, "Warning: id 'v3' does not match file name 'copy'\n"], [r.status, r.err]
  end

  def test_dry_run
    before = File.read(path('v3.json'))
    assert_equal report('v3.json', 'would rename "port" to "p"'),
                 eedbi('rename', path('v3.json'), 'port', 'p', '--dry-run', secret: false).out
    assert_equal before, File.read(path('v3.json'))
  end
end
