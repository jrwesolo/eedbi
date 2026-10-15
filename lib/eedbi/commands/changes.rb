# frozen_string_literal: true

module Eedbi
  module Commands
    # Describes what a save changes, by key name only, never values, like
    # check: 'add "a", change "b"', or done: 'added "a", changed "b"'. The
    # id, which is not encrypted, is shown: 'changed id 'a' to 'b''.
    module Changes
      PAST_TENSE = { 'create' => 'created', 'add' => 'added', 'change' => 'changed', 'remove' => 'removed',
                     'reorder' => 'reordered', 'set' => 'set' }.freeze

      module_function

      # Whether saving `after` over `before` changes the file. Key order
      # matters too, since it is preserved in the written file. A moved id
      # alone is no change; it is put first on the next real one.
      def any?(before, after)
        before = Item.id_first(before)
        after = Item.id_first(after)
        !(before.eql?(after) && before.keys.eql?(after.keys))
      end

      # Keys whose value is new or different.
      def changed_keys(before, after)
        after.keys.reject { |key| key == 'id' || (before.key?(key) && before[key].eql?(after[key])) }
      end

      # A new item's id is left out, since every item has one. An existing
      # file with no keys, such as {}, is not a new item.
      def describe(before, after, new_item: false, done: false)
        verb = ->(word) { done ? PAST_TENSE.fetch(word) : word }
        return "#{verb.call('create')} the item#{quoted(' with ', after.keys - ['id'])}" if new_item

        described = by_verb(before.except('id'), after.except('id')).map do |word, keys|
          quoted("#{verb.call(word)} ", keys)
        end
        described << id_change(before['id'], after['id'], verb) if before['id'] != after['id']
        described.empty? ? "#{verb.call('reorder')} the keys" : described.join(', ')
      end

      # The id is not encrypted, so its values are shown.
      def id_change(old, new, verb)
        old.nil? ? "#{verb.call('set')} id '#{new}'" : "#{verb.call('change')} id '#{old}' to '#{new}'"
      end

      def by_verb(before, after)
        changed = (before.keys & after.keys).reject { |key| before[key].eql?(after[key]) }
        { 'add' => after.keys - before.keys, 'change' => changed, 'remove' => before.keys - after.keys }
          .reject { |_, keys| keys.empty? }
      end

      def quoted(prefix, keys)
        keys.empty? ? '' : "#{prefix}#{Eedbi.quote_keys(keys)}"
      end
    end
  end
end
