# frozen_string_literal: true

require_relative '../test_helper'
require_relative '../fuzz_inputs'

# Malformed input of every kind, given to every command. Whatever the input,
# the result must be an exit status of 0, 1 or 2, with a message for 1 and
# 2, and never a Ruby exception or backtrace.
#
# The cases come from FuzzInputs. A failure names the seed, the case and
# the input, so it can be turned into a test of its own.
class FuzzTest < Minitest::Test
  include EedbiTestHelper
  include FuzzInputs

  def test_malformed_input_never_raises
    rng = Random.new(SEED)
    CASES.times do |index|
      bytes = item_bytes(rng)
      input = item_bytes(rng)
      commands.each do |args, options|
        File.binwrite(path('f.json'), bytes)
        options = options.merge(stdin: input) if options[:stdin] == :item
        label = "seed #{SEED}, case #{index}: eedbi #{args.join(' ')}\nitem: #{bytes.inspect[0, 400]}" \
                "#{"\nstdin: #{options[:stdin].inspect[0, 400]}" if options[:stdin]}"
        check_result(label, args, options)
      end
    end
  end

  private

  def check_result(label, args, options)
    r = eedbi(*args, **options)
  rescue StandardError, SystemStackError => e
    flunk "#{label}\nraised #{e.class}: #{e.message}\n#{e.backtrace.first(6).join("\n")}"
  else
    assert_includes [0, 1, 2], r.status, "#{label}\n#{r.err}"
    refute_match(/\.rb:\d+:in /, r.err, label)
    refute_empty "#{r.out}#{r.err}", "#{label}\nexit #{r.status} without a message" unless r.status.zero?
  end

  # Every command, on f.json. :item stands for the stdin of the case.
  def commands
    f = path('f.json')
    other = path('other_secret')
    [
      [['read', f], {}], [['read', f, 'password'], {}], [['read', f, '--digest'], {}],
      [['read', '-'], { stdin: :item, interactive: false }],
      [['list', f, '--versions'], { secret: false }],
      [['list', f, '--format', 'json', '--versions'], { secret: false }],
      [['list', '-'], { stdin: :item, interactive: false, secret: false }],
      [['check', f], {}], [['check', f, '--no-decrypt', '--format', 'json'], { secret: false }],
      [['check', '-'], { stdin: :item, interactive: false }],
      [['migrate', f], {}], [['migrate', f, '--encrypt-version', '1', '--allow-downgrade'], {}],
      [['rekey', f, '--new-secret-file', other], {}],
      [['unset', f, 'password', '--ignore-missing'], { secret: false }],
      [['rename', f, 'password', 'renamed'], { secret: false }],
      [['set', f, 'password'], { stdin: 'x', interactive: false }],
      [['set', f, 'nested', '--json-value'], { stdin: :item, interactive: false }],
      [['write', f], { stdin: :item, interactive: false }],
      [['write', f, '--force', '--encrypt-version', '2'], { stdin: :item, interactive: false }],
      [['import', f], { stdin: :item, interactive: false, secret: false }],
      [['edit', f, '--editor', 'true'], {}], [['edit', f, 'password', '--editor', 'true'], {}]
    ]
  end
end
