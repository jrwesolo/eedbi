# frozen_string_literal: true

require_relative '../test_helper'

# Eedbi::Store: JSON input and file writing.
class StoreTest < Minitest::Test
  include EedbiTestHelper

  def test_byte_order_mark_is_accepted
    assert_equal({ 'a' => 1 }, Eedbi::Store.parse_json("\xEF\xBB\xBF{\"a\":1}".b))
  end

  def test_duplicate_keys_are_rejected_at_any_depth
    ['{"a":1,"a":2}', '{"x":{"y":1,"y":2}}'].each do |json|
      error = assert_raises(Eedbi::DuplicateKeyError, json) { Eedbi::Store.parse_json(json) }
      assert_match(/\ADuplicate key "[ay]"/, error.message)
    end
  end

  # Items already on disk with repeated keys must keep loading.
  def test_duplicate_keys_are_tolerated_when_reading_an_item
    File.write(path('dup.json'), '{"id":"dup","a":1,"a":2}')
    assert_equal({ 'id' => 'dup', 'a' => 2 }, Eedbi::Store.read(path('dup.json')).item)
  end

  # json 2 accepts invalid UTF-8 in strings, which then fails in a regex
  # match or when written, with a stack trace.
  def test_invalid_utf8_is_rejected
    error = assert_raises(Eedbi::Error) { Eedbi::Store.parse_json("{\"a\":\"\xFF\"}".b) }
    assert_equal 'The JSON is not valid UTF-8', error.message
    File.binwrite(path('bad.json'), "{\"id\":\"bad\",\"a\":\"\xFF\"}")
    error = assert_raises(Eedbi::Error) { Eedbi::Store.read(path('bad.json')) }
    assert_equal "#{path('bad.json')}: not valid UTF-8, which JSON requires", error.message
    error = assert_raises(Eedbi::Error) { Eedbi::Store.read_stream(StringIO.new("{\"\xFF\":1}".b)) }
    assert_equal 'Data bag item from stdin is not valid UTF-8', error.message
  end

  # Read as Infinity, which JSON cannot write back when the item is saved.
  def test_numbers_too_large_are_rejected
    ['{"a":1e400}', '{"a":[-1e400]}', '{"a":{"b":1e999}}'].each do |json|
      error = assert_raises(Eedbi::Error, json) { Eedbi::Store.parse_json(json) }
      assert_equal 'The JSON has a number too large to keep (it reads as Infinity)', error.message
    end
    assert_equal({ 'a' => 1e300 }, Eedbi::Store.parse_json('{"a":1e300}'))
  end

  def test_read_missing_file
    loaded = Eedbi::Store.read(path('missing.json'))
    refute loaded.exist?
    assert_equal({}, loaded.item)
  end

  def test_read_rejects_non_objects_and_bad_json
    File.write(path('array.json'), '[]')
    File.write(path('broken.json'), '{')
    assert_raises(Eedbi::Error) { Eedbi::Store.read(path('array.json')) }
    assert_raises(Eedbi::Error) { Eedbi::Store.read(path('broken.json')) }
  end

  def test_changed_on_disk
    loaded = Eedbi::Store.read(path('v3.json'))
    refute loaded.changed_on_disk?
    File.write(path('v3.json'), "#{File.read(path('v3.json'))} ")
    assert loaded.changed_on_disk?
  end

  def test_write_atomic_uses_lf_and_leaves_no_temp_file
    Eedbi::Store.write_atomic(path('out.json'), "{\n}\n")
    assert_equal "{\n}\n", File.binread(path('out.json'))
    assert_empty Dir.glob(path('.out.json.*'))
  end

  def test_write_atomic_keeps_mode
    skip 'POSIX permissions only' if WINDOWS

    File.chmod(0o640, path('v3.json'))
    Eedbi::Store.write_atomic(path('v3.json'), "{}\n")
    assert_equal 0o640, File.stat(path('v3.json')).mode & 0o777
  end

  def test_write_atomic_through_symlink_keeps_symlink
    skip 'symlinks need privileges on Windows' if WINDOWS

    FileUtils.mkdir(path('real'))
    FileUtils.mv(path('v3.json'), path('real', 'v3.json'))
    File.symlink(path('real', 'v3.json'), path('v3.json'))
    Eedbi::Store.write_atomic(path('v3.json'), "{}\n")
    assert File.symlink?(path('v3.json'))
    assert_equal "{}\n", File.read(path('real', 'v3.json'))
  end

  def test_check_writable
    Eedbi::Store.check_writable!(path('new.json'))
    error = assert_raises(Eedbi::Error) { Eedbi::Store.check_writable!(path('missing', 'new.json')) }
    assert_match(/Directory not found/, error.message)
  end

  # The target probably moved; writing would replace the link with a new
  # item in the old place.
  def test_dangling_symlink_is_refused
    skip 'symlinks need privileges on Windows' if WINDOWS

    File.symlink(path('moved.json'), path('link.json'))
    error = assert_raises(Eedbi::Error) { Eedbi::Store.read(path('link.json')) }
    assert_equal "#{path('link.json')} is a symlink to a missing file (#{path('moved.json')})", error.message
  end
end
