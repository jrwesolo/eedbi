# frozen_string_literal: true

require_relative '../test_helper'

# Chef allows // and /* */ comments in items. Like knife, eedbi reads them
# and does not keep them when it writes an item.
class CommentsTest < Minitest::Test
  include EedbiTestHelper

  def setup
    super
    File.write(path('v3.json'), File.read(path('v3.json')).sub("{\n", "{\n  // owner: db team\n"))
  end

  def test_reading_works
    assert_equal "hunter2\n", eedbi('read', path('v3.json'), 'password').out
    assert_equal 0, eedbi('check', path('v3.json')).status
  end

  def test_writing_drops_them
    r = eedbi('set', path('v3.json'), 'password', stdin: 'x', interactive: false)
    assert_equal report('v3.json', 'changed "password"'), r.out, r.err
    assert_empty r.err
    refute_includes File.read(path('v3.json')), 'owner'
  end

  def test_unchanged_item_is_left_alone
    before = File.read(path('v3.json'))
    r = eedbi('set', path('v3.json'), 'password', stdin: 'hunter2', interactive: false)
    assert_equal report('v3.json', 'no changes'), r.out
    assert_equal before, File.read(path('v3.json'))
  end

  def test_comments_in_input_are_dropped
    r = eedbi('write', path('new.json'), stdin: %({"id":"new", /* x */ "a": 1 // note\n}), interactive: false)
    assert_equal 0, r.status, r.err
    assert_equal({ 'id' => 'new', 'a' => 1 }, decrypt('new.json'))
  end
end
