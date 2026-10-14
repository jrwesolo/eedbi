# frozen_string_literal: true

require_relative '../test_helper'

# Inputs shared by commands: what stdin may carry, and the decrypt minimum
# version.
class InputsTest < Minitest::Test
  include EedbiTestHelper

  # stdin carries only items and values; the secret never comes from it.
  def test_secret_cannot_come_from_stdin
    r = eedbi('read', path('v3.json'), '--secret-file', '-', stdin: secret, interactive: false, secret: false)
    assert_equal 2, r.status
    assert_match(/The secret cannot come from stdin/, r.err)

    r = eedbi('rekey', path('v3.json'), '--new-secret-file', '-', stdin: secret('other_secret'), interactive: false)
    assert_equal 2, r.status
    assert_match(/The secret cannot come from stdin/, r.err)
  end

  # So the secret can be typed while stdin carries the item.
  def test_secret_prompt_with_the_item_on_stdin
    r = eedbi('write', path('new.json'), '--secret-prompt',
              stdin: JSON.generate(plain('new')), interactive: false, secret: false, console: FakeConsole.new(secret))
    assert_equal 0, r.status, r.err
    assert_equal plain('new'), decrypt('new.json')
  end

  def test_decrypt_minimum_refuses_older_values
    r = eedbi('read', path('v1.json'), '--decrypt-minimum-version', '2')
    assert_equal 1, r.status
    assert_match(/v1\.json: "password": encryption version 1 is below the minimum 2/, r.err)
    assert_match(/'eedbi migrate' can upgrade it/, r.err)
    assert_equal 0, eedbi('read', path('v2.json'), '--decrypt-minimum-version', '2').status
  end

  def test_decrypt_minimum_from_the_environment
    with_env('EEDBI_DECRYPT_MINIMUM_VERSION' => '3') do
      assert_equal 1, eedbi('read', path('v2.json')).status
      assert_equal 0, eedbi('read', path('v2.json'), '--decrypt-minimum-version', '2').status, 'the option wins'
    end
    with_env('EEDBI_DECRYPT_MINIMUM_VERSION' => '5') do
      assert_match(/v3\.json: invalid \$EEDBI_DECRYPT_MINIMUM_VERSION '5'/, eedbi('read', path('v3.json')).err)
    end
  end

  def test_decrypt_minimum_applies_to_mixed_items
    r = eedbi('edit', path('mixed.json'), '-e', ruby_editor('nil'), '--decrypt-minimum-version', '1')
    assert_equal 1, r.status
    assert_match(/encryption version 0 is below the minimum 1/, r.err)
  end

  # migrate exists to upgrade values below the minimum.
  def test_migrate_reads_below_the_minimum_and_says_so
    with_env('EEDBI_DECRYPT_MINIMUM_VERSION' => '2') do
      r = eedbi('migrate', '--encrypt-version', '3', path('v1.json'))
      assert_equal 0, r.status, r.err
      assert_match(/reads values below the decrypt minimum version \(2\)/, r.err)
    end
    assert_equal [3], versions('v1.json')
    assert_match(/invalid option: --decrypt-minimum-version/,
                 eedbi('migrate', '--encrypt-version', '3', '--decrypt-minimum-version', '2', path('v1.json')).err)
  end
end
