# frozen_string_literal: true

require_relative '../test_helper'

# Command dispatch, help and option parsing shared by all commands.
class CLITest < Minitest::Test
  include EedbiTestHelper

  def test_no_command_prints_usage_and_fails
    r = eedbi(secret: false)
    assert_equal 2, r.status
    assert_match(/Missing command/, r.err)
    assert_match(/Commands:/, r.err)
  end

  def test_help_lists_every_command
    %w[help --help -h].each do |flag|
      r = eedbi(flag, secret: false)
      assert_equal 0, r.status
      Eedbi::CLI::COMMANDS.each_key { |name| assert_match(/^  #{name} /, r.out, "#{flag} lists #{name}") }
    end
  end

  def test_version
    r = eedbi('--version', secret: false)
    assert_equal 0, r.status
    assert_equal "eedbi #{Eedbi::VERSION}\n", r.out
  end

  def test_unknown_command_suggests_edit_for_an_item
    r = eedbi('v3.json', secret: false)
    assert_equal 2, r.status
    assert_match(/Unknown command 'v3\.json'\. Did you mean 'eedbi edit v3\.json'\?/, r.err)
    assert_match(/Unknown command 'nope'\. Run 'eedbi help'/, eedbi('nope', secret: false).err)
  end

  def test_typos_get_a_suggestion
    assert_match(/Unknown command 'raed'\. Did you mean 'read'\?/, eedbi('raed', secret: false).err)
    r = eedbi('check', path('v3.json'), '--qiuet')
    assert_equal 2, r.status
    assert_match(/invalid option: --qiuet\. Did you mean '--quiet'\?/, r.err)
    assert_match(/invalid argument: --format yaml\n/, eedbi('check', path('v3.json'), '--format', 'yaml').err)
  end

  def test_help_shows_examples_and_environment
    Eedbi::CLI::COMMANDS.each_key do |name|
      assert_match(/^Examples:\n  .*eedbi #{name} /, eedbi('help', name, secret: false).out, name)
    end
    help = eedbi('help', secret: false).out
    assert_match(/^Environment:\n  ENCRYPTED_DATA_BAG_SECRET /, help)
    assert_match(/^Exit status: /, help)
  end

  def test_abbreviated_options_are_rejected
    r = eedbi('read', path('v3.json'), '--ke', 'password')
    assert_equal 2, r.status
    assert_match(/invalid option: --ke/, r.err)
  end

  def test_options_after_arguments_whatever_posixly_correct
    with_env('POSIXLY_CORRECT' => '1') do
      r = eedbi('read', path('v3.json'), 'port', '--digest')
      assert_equal 0, r.status, r.err
      assert_match(/\Ahmac:\h{16}\n\z/, r.out)
    end
  end

  def test_new_items_need_a_json_file_name
    r = eedbi('set', path('example'), 'a', stdin: 'x', interactive: false)
    assert_equal 1, r.status
    assert_match(/example: new items need a \.json file name, as knife expects: .*example\.json$/, r.err)
    refute File.exist?(path('example'))
    r = eedbi('write', path('example'), stdin: '{}', interactive: false)
    assert_match(/new items need a \.json file name/, r.err)
    assert_match(/new items need a \.json file name/, eedbi('edit', path('example'), '-e', ruby_editor('nil')).err)

    # Existing files are read whatever their name.
    FileUtils.cp(path('v3.json'), path('noext'))
    assert_equal "hunter2\n", eedbi('read', path('noext'), 'password').out
  end

  def test_missing_file_suggests_the_json_name
    assert_match(/v3: file not found\. Did you mean .*v3\.json\?/, eedbi('read', path('v3')).err)
    assert_equal "#{path('v3')}: file not found. Did you mean #{path('v3.json')}?\n",
                 eedbi('set', path('v3'), 'a', stdin: 'x', interactive: false).err
    refute_match(/Did you mean/, eedbi('read', path('nothing')).err)
    assert_match(/new items need a \.json file name, as knife expects: .*nothing\.json\n\z/,
                 eedbi('set', path('nothing'), 'a', stdin: 'x', interactive: false).err)
  end

  def test_item_count
    assert_equal 2, eedbi('edit').status
    assert_match(/needs an item/, eedbi('edit').err)
    assert_match(/needs at least one item/, eedbi('check').err)
    assert_match(/takes one item \(received 2 arguments\)/, eedbi('write', path('v1.json'), path('v2.json')).err)
    assert_match(/takes ITEM and an optional KEY \(received 3/, eedbi('edit', path('v1.json'), 'a', 'b').err)
  end

  def test_secret_prompt
    console = FakeConsole.new(secret)
    r = eedbi('read', path('v3.json'), 'password', '--secret-prompt', secret: false, console: console)
    assert_equal 0, r.status, r.err
    assert_equal "hunter2\n", r.out
  end

  def test_secret_found_in_working_directory
    with_env('ENCRYPTED_DATA_BAG_SECRET' => nil) do
      r = eedbi_in_dir('read', 'v3.json', 'password', secret: false)
      assert_equal "hunter2\n", r.out, r.err
    end
  end

  def test_no_secret_anywhere
    FileUtils.rm(path('encrypted_data_bag_secret'))
    with_env('ENCRYPTED_DATA_BAG_SECRET' => nil, 'HOME' => @dir) do
      r = eedbi_in_dir('read', 'v3.json', secret: false)
      skip 'a secret exists in a default location on this machine' if r.status.zero?
      assert_match(/v3\.json: no secret found/, r.err)
    end
  end

  # Errors from a command on one item start with the item, once; usage
  # errors and an item from stdin do not.
  def test_errors_name_the_item
    assert_equal "x.json: no key 'a'", Eedbi.item_message('x.json', "x.json: no key 'a'")
    assert_equal 'x.json changed on disk', Eedbi.item_message('x.json', 'x.json changed on disk')
    assert_equal 'x.json: editor exited with 1', Eedbi.item_message('x.json', 'Editor exited with 1')
    assert_equal 'x.json: JSON from stdin', Eedbi.item_message('x.json', 'JSON from stdin')

    r = eedbi('read', path('v3.json'), '-s', path('missing'), secret: false)
    assert_equal "#{path('v3.json')}: secret file not found: #{path('missing')}\n", r.err
    assert_match(/\AThe id is not encrypted/, eedbi('set', path('v3.json'), 'id', interactive: false).err)
    assert_match(/\Astdin is empty/, eedbi('read', '-', interactive: false).err)
  end

  # Keys are always JSON strings in messages, so that a quote or a newline
  # in one cannot run into the text around it.
  def test_keys_are_quoted_as_json
    assert_equal '"password"', Eedbi.quote_key('password')
    assert_equal %("it's", "a\\nb", "p\u00e4ss"), Eedbi.quote_keys(["it's", "a\nb", "p\u00e4ss"])
    r = eedbi('set', path('v3.json'), "a\nb", stdin: 'x', interactive: false)
    assert_equal report('v3.json', 'added "a\\nb"'), r.out
  end

  def test_system_errors_are_one_line
    skip 'permissions do not apply' if WINDOWS || Process.uid.zero?
    File.chmod(0o000, path('v3.json'))
    r = eedbi('read', path('v3.json'))
    assert_equal 1, r.status
    assert_match(/v3\.json: permission denied/, r.err)
    refute_match(/\.rb:\d+/, r.err, 'printed a backtrace')
  end

  def test_directories_are_reported
    FileUtils.mkdir(path('bag'))
    r = eedbi('read', path('bag'))
    assert_equal 1, r.status
    assert_equal "#{path('bag')} is a directory; pass the items in it, " \
                 "for example #{File.join(path('bag'), '*.json')}\n", r.err

    r = eedbi('check', path('bag'), path('v3.json'))
    assert_match(/^FAIL  .*bag: .*bag is a directory/, r.out)
    assert_match(/^ok    .*v3\.json/, r.out)

    r = eedbi('read', path('v3.json'), '-s', path('bag'), secret: false)
    assert_equal "#{path('v3.json')}: secret file is a directory: #{path('bag')}\n", r.err
  end

  # As in knife, --version works after any command and ignores the rest,
  # instead of OptionParser's own, which printed 'version unknown'.
  def test_version_after_a_command
    version = "eedbi #{Eedbi::VERSION}\n"
    [%w[read --version], %w[list missing.json --version --bogus], %w[edit --version -e]].each do |args|
      r = eedbi(*args, secret: false, interactive: false)
      assert_equal [0, version, ''], [r.status, r.out, r.err], args.join(' ')
    end
    r = with_env('ENCRYPTED_DATA_BAG_SECRET' => path('encrypted_data_bag_secret')) do
      eedbi('read', path('v3.json'), '--', '--version', secret: false)
    end
    assert_match(/no key "--version"/, r.err, 'after --, it is a key')
    assert_includes eedbi('help', 'read', secret: false).out, '--version'

    r = eedbi('version', secret: false)
    assert_equal 2, r.status
    assert_match(/Unknown command 'version'\. Did you mean 'eedbi --version'\?/, r.err)
    assert_equal 2, eedbi('read', path('v3.json'), '--*-completion-bash=x').status
  end

  # Under LANG=C, arguments come labeled US-ASCII; keys are UTF-8.
  def test_arguments_are_utf8_whatever_the_locale
    eedbi('set', path('v3.json'), "cl\u00e9", stdin: 'x', interactive: false)
    r = eedbi('read', path('v3.json'), (+"cl\u00e9").force_encoding(Encoding::US_ASCII))
    assert_equal [0, "x\n"], [r.status, r.out], r.err

    r = eedbi('read', path('v3.json'), (+"\xFF").force_encoding(Encoding::UTF_8))
    assert_equal [2, %(Argument "\\xFF" is not valid UTF-8\n)], [r.status, r.err]
  end

  def test_options_before_the_command_get_a_hint
    r = eedbi('-s', 'secret', 'read', path('v3.json'), secret: false)
    assert_equal 2, r.status
    assert_equal "Option '-s' before the command. Options go after the command: eedbi read [options] ITEM [KEY]\n" \
                 "Run 'eedbi help read' for usage.\n", r.err
    assert_match(/Options go after the command: eedbi COMMAND \[options\]\nRun 'eedbi help' for the list/,
                 eedbi('--quiet', secret: false).err)
    r = eedbi('help', '-x', secret: false)
    assert_equal [2, "Unknown command '-x'. Run 'eedbi help' for the list of commands.\n"], [r.status, r.err]
  end

  def test_help_for_help_and_version_with_help
    assert_equal Eedbi::CLI.usage, eedbi('help', 'help', secret: false).out
    [%w[help --version], %w[--help --version], %w[-h edit --version]].each do |args|
      r = eedbi(*args, secret: false)
      assert_equal [0, "eedbi #{Eedbi::VERSION}\n", ''], [r.status, r.out, r.err], args.join(' ')
    end
  end
end
