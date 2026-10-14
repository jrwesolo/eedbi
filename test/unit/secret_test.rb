# frozen_string_literal: true

require_relative '../test_helper'

# Eedbi::Secret: where the secret comes from.
class SecretTest < Minitest::Test
  include EedbiTestHelper

  def load(**options)
    err = StringIO.new
    [Eedbi::Secret.load(stderr: err, **options), err.string]
  end

  def test_secret_file_is_read_and_stripped
    File.write(path('s'), "  secret\n")
    File.chmod(0o600, path('s'))
    assert_equal ['secret', ''], load(file: path('s'))
  end

  # Chef reads the secret as UTF-8 whatever the locale, so LANG=C, where
  # Ruby's default is US-ASCII, must not break a secret with non-ASCII
  # text. In a child process, since changing the default here warns.
  def test_secret_is_utf8_whatever_the_locale
    File.binwrite(path('s'), "caf\xC3\xA9\n")
    File.chmod(0o600, path('s'))
    script = 'print Eedbi::Secret.load(file: ARGV[0]).unpack1("H*")'
    out = IO.popen([RbConfig.ruby, '-E', 'US-ASCII', '-I', File.expand_path('../../lib', __dir__), '-reedbi',
                    '-e', script, path('s')], &:read)
    assert_equal "caf\u00e9".b.unpack1('H*'), out
  end

  # Chef fails on such a secret, so no node could decrypt what it encrypts.
  def test_invalid_utf8_is_refused
    File.binwrite(path('s'), "se\xFFcret\n")
    error = assert_raises(Eedbi::Error) { load(file: path('s')) }
    assert_equal "Secret file is not valid UTF-8, which Chef cannot load: #{path('s')}", error.message
    error = assert_raises(Eedbi::Error) { load(prompt: true, console: FakeConsole.new("\xFF".b)) }
    assert_match(/typed is not valid UTF-8/, error.message)
  end

  # Text mode, as in Chef: on Windows the CRLF becomes LF, elsewhere it
  # stays, so the same file gives two keys, which is worth a warning.
  def test_crlf_inside_the_secret_warns
    File.binwrite(path('s'), "abc\r\ndef\r\n")
    File.chmod(0o600, path('s'))
    secret, warning = load(file: path('s'))
    assert_equal File.read(path('s')).strip, secret
    assert_match(/CRLF line breaks inside the secret/, warning)
    File.binwrite(path('s'), "abc\ndef\r\n")
    assert_equal '', load(file: path('s')).last, 'LF inside and CRLF at the end read the same everywhere'
  end

  def test_environment_variable_beats_working_directory
    with_env('ENCRYPTED_DATA_BAG_SECRET' => path('other_secret')) do
      assert_equal secret('other_secret'), Dir.chdir(@dir) { load.first }
    end
  end

  def test_home_candidate_is_left_out_without_a_home
    assert_includes Eedbi::Secret.candidates('/home/me'), '/home/me/.chef/encrypted_data_bag_secret'
    refute(Eedbi::Secret.candidates('').any? { |candidate| candidate.include?('.chef') })
  end

  def test_working_directory_candidate
    with_env('ENCRYPTED_DATA_BAG_SECRET' => nil) do
      assert_equal secret, Dir.chdir(@dir) { load.first }
    end
  end

  # Falling back to another file could encrypt with a different secret.
  def test_missing_file_from_environment_is_an_error
    with_env('ENCRYPTED_DATA_BAG_SECRET' => path('missing')) do
      error = assert_raises(Eedbi::Error) { Dir.chdir(@dir) { load } }
      assert_match(/Secret file not found: .*missing \(from \$ENCRYPTED_DATA_BAG_SECRET\)/, error.message)
    end
  end

  def test_empty_file_is_an_error
    File.write(path('empty'), " \n")
    assert_raises(Eedbi::Error) { load(file: path('empty')) }
  end

  def test_prompt
    assert_equal 'typed', load(prompt: true, console: FakeConsole.new(" typed\n")).first
    assert_raises(Eedbi::Error) { load(prompt: true, console: FakeConsole.new('')) }
    error = assert_raises(Eedbi::Error) { load(prompt: true, console: nil) }
    assert_match(/needs a terminal/, error.message)
  end

  def test_file_and_prompt_are_exclusive
    assert_raises(Eedbi::Error) { load(file: path('other_secret'), prompt: true, console: FakeConsole.new('x')) }
  end

  def test_world_readable_file_warns
    skip 'POSIX permissions only' if WINDOWS

    File.chmod(0o644, path('other_secret'))
    _, warning = load(file: path('other_secret'))
    assert_match(/readable by every user .*mode 0644.*chmod o-r/, warning)
  end

  def test_group_readable_file_does_not_warn
    skip 'POSIX permissions only' if WINDOWS

    File.chmod(0o640, path('other_secret'))
    assert_equal '', load(file: path('other_secret')).last
  end

  # stdin carries only items and values.
  def test_dash_is_refused
    error = assert_raises(Eedbi::UsageError) { load(file: '-') }
    assert_match(/cannot come from stdin/, error.message)
  end

  # What <(command) gives: a pipe, read like a file, with no mode to warn about.
  def test_named_pipe
    skip 'no named pipes' if WINDOWS

    File.mkfifo(path('fifo'))
    writer = Thread.new { File.write(path('fifo'), "piped\n") }
    assert_equal ['piped', ''], load(file: path('fifo'))
    writer.join
  end

  def test_prompt_confirmation
    assert_equal 's', Eedbi::Secret.from_prompt(FakeConsole.new('s'), confirm: true)
    assert_raises(Eedbi::Error) { Eedbi::Secret.from_prompt(FakeConsole.new('s', 't'), confirm: true) }
  end
end
