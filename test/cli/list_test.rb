# frozen_string_literal: true

require_relative '../test_helper'

class ListTest < Minitest::Test
  include EedbiTestHelper

  def list(*args, **options)
    eedbi('list', *args, secret: false, **options)
  end

  def test_lists_key_names_without_a_secret
    with_env('ENCRYPTED_DATA_BAG_SECRET' => path('no_such_secret')) do
      r = list(path('mixed.json'))
      assert_equal 0, r.status, r.err
      assert_equal plain('mixed').keys - ['id'], r.out.lines.map(&:chomp)
    end
  end

  def test_versions
    lines = list('--versions', path('mixed.json')).out.lines.map(&:split)
    assert_equal plain('mixed').keys - ['id'], lines.map(&:first)
    assert_equal %w[0 1 2 3], lines.map(&:last).uniq.sort
    assert_equal ['unencrypted'], list('--versions', path('plain.json')).out.lines.map { |line| line.split.last }.uniq
  end

  def test_unsupported_versions
    field = read_json('v3.json')['password']
    File.write(path('odd.json'), JSON.generate('id' => 'odd', 'a' => field.merge('version' => 9),
                                               'b' => field.merge('version' => '3'),
                                               'c' => field.merge('version' => 3.0)))
    assert_equal "a  unsupported (9)\nb  unsupported (\"3\")\nc  unsupported (3.0)\n",
                 list('--versions', path('odd.json')).out
  end

  def test_json
    assert_equal plain('v3').keys - ['id'], JSON.parse(list('--format', 'json', path('v3.json')).out)
    versions = JSON.parse(list('--format', 'json', '--versions', path('mixed.json')).out)
    assert_equal plain('mixed').keys - ['id'], versions.keys
    assert_equal [0, 1, 2, 3], versions.values.uniq.sort
    assert_equal [nil], JSON.parse(list('--format', 'json', '--versions', path('plain.json')).out).values.uniq
  end

  def test_takes_one_item
    assert_match(/takes one item \(received 2 arguments\)/, list(path('v1.json'), path('v3.json')).err)
  end

  def test_secret_options_are_rejected
    assert_equal 2, list(path('v3.json'), '-s', path('encrypted_data_bag_secret')).status
    assert_equal 2, list(path('v3.json'), '--decrypt-minimum-version', '2').status
  end

  def test_item_from_stdin
    r = list('-', stdin: File.read(path('v3.json')), interactive: false)
    assert_equal "password\n", r.out.lines.first, r.err
    assert_match(/stdin is empty/, list('-', stdin: '', interactive: false).err)
  end

  def test_missing_file
    r = list(path('missing.json'))
    assert_equal 1, r.status
    assert_match(/missing\.json: file not found/, r.err)
  end

  # A reader that stopped early, as `| head -1` does, is no error worth a
  # message. 141 is what a shell reports for a program killed by SIGPIPE.
  def test_closed_output_pipe_exits_quietly
    r = eedbi('list', path('v3.json'), secret: false, stdout: stdout_closed)
    assert_equal [141, ''], [r.status, r.err]
  end
end
