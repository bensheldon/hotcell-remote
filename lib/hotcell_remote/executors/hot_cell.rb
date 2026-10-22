# frozen_string_literal: true

require "hot_cell/client"

module HotcellRemote
  module Executors
    # Sends each operation to a Hot Cell over its UNIX socket, passing the input and output as descriptors.
    # The cell runs the same operation classes, wrapped by hotcell_remote/cell.
    class HotCell
      # Hot Cell's default socket directory is /run/hotcell/cell, so the cell is named "cell".
      CELL = "cell"

      def initialize(timeout: 60)
        ::HotCell.register CELL, timeout:, permanent: PermanentError, transient: TransientError
        @clients = Hash.new do |clients, name|
          clients[name] = Class.new(::HotCell::Client) do
            hotcell CELL
            operation name
          end
        end
      end

      def call(operation, input, output, payload)
        File.open(input, "rb") do |source|
          next @clients[operation].perform_in_hotcell(source, [], payload) if HotcellRemote.operations.fetch(operation).result_only?

          File.open(output, "wb") { |destination| @clients[operation].perform_in_hotcell(source, destination, payload) }
        end
      end
    end
  end
end
