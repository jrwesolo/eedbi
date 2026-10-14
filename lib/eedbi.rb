# frozen_string_literal: true

# eedbi: edit Chef encrypted data bag items.
#
# Only the Ruby standard library is required. The encryption formats are
# implemented to match Chef's Chef::EncryptedDataBagItem.
# https://docs.chef.io/client/latest/policy/data_bags/#encryption-versions

require 'json'
require 'openssl'
require 'optparse'
require 'rbconfig'
require 'securerandom'
require 'shellwords'
require 'tmpdir'

# Edit Chef encrypted data bag items. See Eedbi.main for the entry point.
module Eedbi
  class Error < StandardError; end
  # A mistake in the command line itself, found before any file is read.
  class UsageError < Error; end
  class DecryptionError < Error; end
  class NotEncryptedError < Error; end
  class BelowMinimumError < DecryptionError; end
  class DuplicateKeyError < Error; end

  # JSON object class for input typed or piped by the user. JSON allows
  # repeated keys and keeps the last value, which silently drops the other,
  # almost always a copy and paste mistake.
  class UniqueKeyHash < Hash
    def []=(key, value)
      raise DuplicateKeyError, "Duplicate key #{key.inspect}" if key?(key)

      super
    end
  end

  # Matches Chef::DataBagItem::VALID_ID
  VALID_ID = /\A[.\-[:alnum:]_]+\z/

  WINDOWS = RbConfig::CONFIG['host_os'].match?(/mswin|mingw/)

  HOME = begin
    Dir.home
  rescue ArgumentError
    ''
  end

  # " Did you mean 'x'?" for a mistyped command or option, or ''. The
  # did_you_mean gem ships with Ruby but is missing under --disable-gems.
  def self.suggestion(word, candidates)
    require 'did_you_mean'
    match = DidYouMean::SpellChecker.new(dictionary: candidates).correct(word).first
    match ? " Did you mean '#{match}'?" : ''
  rescue LoadError
    ''
  end

  # A key name in a message: always as a JSON string, so that a quote or a
  # newline in it cannot be confused with the text around it, and scripts
  # can decode it. Keys are valid UTF-8: from JSON, or arguments checked by
  # CLI#run.
  def self.quote_key(key)
    JSON.generate(key)
  end

  # Keys as a list: "a", "b".
  def self.quote_keys(keys)
    keys.map { |key| quote_key(key) }.join(', ')
  end

  # "PATH: message" for an error about one item. A message that already
  # starts with the path is left alone; otherwise it continues in lowercase,
  # as in "x.json: no key 'a'".
  def self.item_message(path, message)
    return message if message.match?(/\A#{Regexp.escape(path)}[: ]/)

    "#{path}: #{message.sub(/\A[A-Z](?=[a-z])/, &:downcase)}"
  end

  # Entry point for bin/eedbi. Returns the exit status: 2 for usage errors,
  # so that scripts can tell a typo from an item that failed.
  def self.main(argv, **streams)
    CLI.new(argv, **streams).run
  rescue UsageError => e
    (streams[:stderr] || $stderr).puts e.message
    2
  rescue Errno::EPIPE
    # The output was piped to a reader that stopped, as `| head -1` does,
    # which is no error worth a message. 141 is what a shell reports for a
    # program killed by SIGPIPE (128 + 13). Exiting through Ruby, rather
    # than by the signal, still runs the cleanup of temporary files.
    141
  rescue Error, SystemCallError => e
    # SystemCallError: for example an unreadable secret file, or a directory
    # given where a file is expected.
    (streams[:stderr] || $stderr).puts e.message
    1
  rescue Interrupt
    (streams[:stderr] || $stderr).puts "\nInterrupted"
    130
  end
end

require_relative 'eedbi/version'
require_relative 'eedbi/crypto'
require_relative 'eedbi/item'
require_relative 'eedbi/editor'
require_relative 'eedbi/secret'
require_relative 'eedbi/store'
require_relative 'eedbi/commands/options'
require_relative 'eedbi/commands/changes'
require_relative 'eedbi/commands/item_input'
require_relative 'eedbi/commands/base'
require_relative 'eedbi/commands/edit'
require_relative 'eedbi/commands/read'
require_relative 'eedbi/commands/list'
require_relative 'eedbi/commands/write'
require_relative 'eedbi/commands/import'
require_relative 'eedbi/commands/set'
require_relative 'eedbi/commands/unset'
require_relative 'eedbi/commands/rename'
require_relative 'eedbi/commands/check'
require_relative 'eedbi/cli'
