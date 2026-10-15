# frozen_string_literal: true

module Eedbi
  module Commands
    # Rewriting many items at once, for migrate and rekey.
    module Rewrite
      private

      # Rewrites many items in two passes. First the block decrypts and
      # re-encrypts each item in memory, returning the new encrypted item,
      # or nil to leave it alone, and the line that reports it. Only when
      # all items succeeded is anything written, so a wrong secret or one
      # broken item never leaves a set of items half converted. An item
      # that check would fail, such as one without an id, is refused rather
      # than written again. --dry-run stops after the first pass.
      #
      # The second pass writes what it can: a write that fails, as when
      # someone else changed the file meanwhile, has nothing to do with the
      # other items, and stopping would only leave more of them undone.
      def rewrite_all(paths)
        planned = []
        failures = paths.filter_map do |path|
          loaded = read_existing(path)
          Item.validate!(loaded.item)
          Store.check_writable!(path)
          planned << [loaded, *yield(loaded)]
          nil
        rescue Error, SystemCallError => e
          Eedbi.item_message(path, e.message)
        end
        unless failures.empty?
          raise Error, "#{failures.join("\n")}\nNothing was written (#{failures.size} of #{paths.size} items failed)"
        end
        return report_dry_run(planned) if dry_run?

        failed = planned.count { |loaded, encrypted, line| !write_and_report(loaded, encrypted, line) }
        return if failed.zero?

        raise Error, "#{failed} of #{planned.size} items #{failed == 1 ? 'was' : 'were'} not written. " \
                     'Run the same command again to finish.'
      end

      def report_dry_run(planned)
        planned.each { |_, _, line| stdout.puts line }
        stdout.puts 'Dry run: nothing was written'
      end

      # Writes one planned item, if it changed, and reports it. Returns
      # whether it was written. Flushed, so that in a log of both streams
      # each line stays next to its errors.
      def write_and_report(loaded, encrypted, line)
        written = write_changed(loaded, encrypted)
        if written
          stdout.puts line
          stdout.flush
        end
        written
      end

      # Writes the item if it changed. Only the write is rescued: a failure
      # to print the report, such as a closed pipe, comes after the item
      # was written, and is no reason to call it unwritten.
      def write_changed(loaded, encrypted)
        return true unless encrypted
        raise Error, "#{loaded.path} changed on disk while eedbi was running" if loaded.changed_on_disk?

        Store.write_atomic(loaded.path, Store.dump(encrypted))
        true
      rescue Error, SystemCallError => e
        stderr.puts "#{Eedbi.item_message(loaded.path, e.message)}; not written"
        false
      end
    end
  end
end
