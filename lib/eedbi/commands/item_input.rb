# frozen_string_literal: true

module Eedbi
  module Commands
    # A whole item as JSON from stdin or --from-file, for write and import.
    module ItemInput
      private

      def read_item_input
        text = reads_stdin? ? stdin.read.to_s : read_from_file(@options[:from_file])
        raise Error, "#{input_label} is empty (expected the item as JSON)" if text.b.strip.empty?

        item = Store.parse_json(text, not_utf8: "#{input_label} is not valid UTF-8")
        raise Error, "JSON from #{input_label} must be an object" unless item.is_a?(Hash)

        item
      rescue JSON::ParserError
        raise Error, "Unable to parse JSON from #{input_label}"
      end

      # The file name decides the id, as knife upload requires: a missing id
      # is filled in, and a different one replaced. An id that came from
      # elsewhere, as when an item is copied from another, gets a note, since
      # it may mean the wrong file; the item's own old id shows in the
      # report of changes instead. A file not named *.json keeps the id it
      # is given, since knife does not read it anyway. Either way, the id
      # goes first.
      def with_file_id(path, item, old_id)
        return Item.id_first(item) unless path.end_with?('.json')

        id = ::File.basename(path, '.json')
        unless id.match?(VALID_ID)
          raise Error, "the file name gives an invalid item id '#{id}' (allowed: letters, numbers, '.', '-', '_')"
        end

        given = item['id']
        if item.key?('id') && given != id && given != old_id
          stderr.puts "Note: id #{given.is_a?(String) ? "'#{given}'" : JSON.generate(given)} from the input " \
                      "replaced with '#{id}', from the file name"
        end
        Item.id_first(item.merge('id' => id))
      end
    end
  end
end
