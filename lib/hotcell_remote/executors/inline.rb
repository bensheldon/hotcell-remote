# frozen_string_literal: true

module HotcellRemote
  module Executors
    # Runs operations in this process, without isolation. For development and test only.
    class Inline
      def call(operation, input, output, payload)
        HotcellRemote.operations.fetch(operation).new.perform(input, output, **payload.transform_keys(&:to_sym))
      end
    end
  end
end
