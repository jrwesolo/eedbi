# frozen_string_literal: true

require_relative '../test_helper'

class ImportTest < Minitest::Test
  include EedbiTestHelper

  def import(name, json, *args)
    text = json.is_a?(String) ? json : JSON.generate(json)
    eedbi('import', path(name), *args, stdin: text, interactive: false, secret: false)
  end

  def encrypted(name, id = File.basename(name, '.json'))
    read_json(name).merge('id' => id)
  end

  # No secret: the ciphertext is written as given, id first.
  def test_writes_the_ciphertext_as_is
    item = encrypted('v2.json', 'v3')
    r = import('v3.json', { 'password' => item['password'] }.merge(item))
    assert_equal 0, r.status, r.err
    assert_match(/\A#{Regexp.escape(path('v3.json'))}: changed "password", /, r.out)
    assert_equal item, read_json('v3.json')
    assert_equal 'id', read_json('v3.json').keys.first
    assert_equal plain('v3'), decrypt('v3.json')
  end

  def test_new_item_and_no_changes
    assert_equal report('new.json', 'created the item with "password"'),
                 import('new.json', 'id' => 'new', 'password' => read_json('v3.json')['password']).out
    assert_equal report('v3.json', 'no changes'), import('v3.json', File.read(path('v3.json'))).out
  end

  def test_dry_run_and_from_file
    before = File.read(path('v3.json'))
    File.write(path('old.json'), JSON.generate(encrypted('v1.json', 'v3')))
    r = eedbi('import', path('v3.json'), '--from-file', path('old.json'), '--dry-run', secret: false)
    assert_equal 0, r.status, r.err
    assert_match(/v3\.json: would change "password", /, r.out)
    assert_equal before, File.read(path('v3.json'))
  end

  def test_plaintext_is_refused
    r = import('v3.json', plain('v3'))
    assert_equal 1, r.status
    assert_match(/\A.*v3\.json: not encrypted: "password", .*To encrypt plaintext, use 'eedbi write'\.\n\z/, r.err)
    r = import('v3.json', plain('other'))
    assert_match(/\A.*v3\.json: not encrypted: .*\n\z/, r.err, 'no note about the id when nothing is written')
    r = import('v3.json', 'id' => 'v3', 'a' => { 'encrypted_data' => 'x', 'version' => 9 })
    assert_match(/v3\.json: "a": unsupported encryption version 9/, r.err)
  end

  # A version 0 value is a bare base64 string, which plaintext can pass for.
  def test_version_0_is_refused
    r = import('p.json', 'id' => 'p', 'a' => 'abcdefghijklmnopqrstuv==')
    assert_equal 1, r.status
    assert_match(/p\.json: uses encryption version 0 \("a"\), which plaintext can pass for\. .*'eedbi migrate'/, r.err)
    assert_match(/version 0 \("password", "enabled", "nested"\)/, import('mixed.json', encrypted('mixed.json')).err)
  end

  def test_decrypt_minimum_applies
    r = import('v3.json', encrypted('v1.json', 'v3'), '--decrypt-minimum-version', '2')
    assert_equal [1, "#{path('v3.json')}: uses encryption version 1 (minimum 2)\n"], [r.status, r.err]
  end

  def test_invalid_input
    assert_match(/not encrypted: "a"/, import('v3.json', 'a' => 1).err)
    assert_match(/v3\.json: unable to parse JSON from stdin/, import('v3.json', '{').err)
    assert_match(/stdin is empty/, import('v3.json', '').err)
    assert_match(/v3\.json: stdin is not valid UTF-8/, import('v3.json', "{\"a\":\"\xFF\"}".b).err)
    r = eedbi('import', path('v3.json'), interactive: true, secret: false)
    assert_match(/stdin is a terminal/, r.err)
  end

  # Such as after a merge conflict, which import is a way out of.
  def test_replaces_an_invalid_item
    File.write(path('v3.json'), "<<<<<<< HEAD\n")
    r = import('v3.json', encrypted('v2.json', 'v3'))
    assert_equal [0, report('v3.json', 'replaced the invalid item')], [r.status, r.out], r.err
    assert_equal plain('v3'), decrypt('v3.json')
  end

  # As with write, the file name decides the id, as when an item is copied
  # from another; the ciphertext does not depend on it.
  def test_id_comes_from_the_file_name
    r = import('copy.json', read_json('v3.json'))
    assert_equal [0, "Note: id 'v3' from the input replaced with 'copy', from the file name\n"], [r.status, r.err]
    assert_equal 'copy', read_json('copy.json')['id']
    assert_equal plain('copy'), decrypt('copy.json')
  end

  # A file not named *.json keeps its id, but still first.
  def test_other_files_keep_their_id
    item = read_json('v3.json')
    File.write(path('copy.item'), "{}\n")
    r = import('copy.item', item.except('id').merge('id' => 'v3'))
    assert_equal [0, ''], [r.status, r.err]
    assert_equal ['id', *item.keys - ['id']], read_json('copy.item').keys
  end

  def test_takes_no_secret
    r = eedbi('import', path('v3.json'), stdin: '{}', interactive: false)
    assert_equal 2, r.status
    assert_match(/invalid option: -s/, r.err)
  end
end
