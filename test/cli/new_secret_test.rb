# frozen_string_literal: true

require_relative '../test_helper'

class NewSecretTest < Minitest::Test
  include EedbiTestHelper

  def new_secret(*args)
    eedbi('new-secret', *args, secret: false, interactive: false)
  end

  # As in Chef's documentation: openssl rand -base64 512 | tr -d '\r\n'.
  def test_creates_a_random_secret_like_chef_recommends
    r = new_secret(path('new_secret'))
    assert_equal [0, report('new_secret', 'created a new secret'), ''], [r.status, r.out, r.err]
    text = File.read(path('new_secret'))
    assert_match(%r{\A[A-Za-z0-9+/]+=*\z}, text, 'one line of base64')
    assert_equal 512, text.unpack1('m0').bytesize
    assert_equal 0o600, File.stat(path('new_secret')).mode & 0o777 unless WINDOWS

    new_secret(path('another'))
    refute_equal text, File.read(path('another'))
    assert_includes eedbi('help', 'new-secret').out, %(openssl rand -base64 512 | tr -d '\\r\\n'), 'in help'
  end

  # Overwriting a secret would lock everyone out of the items encrypted
  # with it.
  def test_never_overwrites
    before = File.read(path('other_secret'))
    r = new_secret(path('other_secret'))
    assert_equal 1, r.status
    assert_match(/other_secret already exists\. A secret is never overwritten/, r.err)
    assert_equal before, File.read(path('other_secret'))
  end

  def test_usage
    r = new_secret
    assert_equal [2, "eedbi new-secret needs a PATH\nRun 'eedbi help new-secret' for usage.\n"], [r.status, r.err]
    r = new_secret(path('a'), path('b'))
    assert_equal [2, "eedbi new-secret takes one PATH (received 2 arguments)\n"], [r.status, r.err]
    r = new_secret('-')
    assert_equal [2, "eedbi new-secret writes a file and never prints the secret: give a PATH\n"], [r.status, r.err]
    assert_match(/invalid option: -s/, new_secret(path('x'), '-s', path('encrypted_data_bag_secret')).err)
    assert_match(/secret: directory not found/, new_secret(path('missing', 'secret')).err)
  end

  def test_rekey_with_a_new_secret
    new_secret(path('new_secret'))
    assert_equal 0, eedbi('rekey', path('v3.json'), '--new-secret-file', path('new_secret')).status
    assert_equal plain('v3'), decrypt('v3.json', secret('new_secret'))
  end
end
