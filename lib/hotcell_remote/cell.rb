# frozen_string_literal: true

require "hot_cell/server"
require "hotcell_remote"

# Serves each HotcellRemote operation from a Hot Cell as it's defined, so require this from the cell's
# config.rb, before the cell loads the operation files. Operations read and write the caller's descriptors in
# place, and their tools receive the input descriptor through run_tool.
HotcellRemote.on_register do |operation_class|
  Class.new(HotCell::Operation) do
    operation operation_class.operation
    unreadable HotcellRemote::UnreadableInput

    define_method(:perform) do |inputs, outputs, **payload|
      tool_runner = lambda do |command|
        result = run_tool(*command, pass: inputs.map(&:to_io), capture: 16 * 1024 * 1024)
        [result.out, result.err, result.ok?]
      end
      operation_class.new(run_tool: tool_runner).perform(inputs.first.fd_path, outputs.first&.fd_path, **payload)
    end
  end
end
