# frozen_string_literal: true

require "hot_cell/server"
require "tmpdir"

module HotcellRemote
  module Transports
    # A Hot Cell transport that runs each request in this process, for parity in development and test. It runs
    # the operation the way a Hot Cell worker does, and answers with the same codes, but there's no isolation:
    # no fork, no limits, and no separate user.
    class Inline
      def initialize(operations_path)
        HotcellRemote.load_operations(operations_path) if operations_path
      end

      def call(cell, line, descriptors, socket: cell.work_socket, timeout: nil) # rubocop:disable Lint/UnusedMethodArgument
        return HotCell::Response.ok(result: {}) if socket == cell.control_socket

        request = HotCell::Request.parse(line)
        operation = HotCell::Registry.lookup(request.op)
        return failed("unsupported", "no operation named #{request.op.inspect}") if operation.nil?

        response = Dir.mktmpdir("hotcell-remote") { |scratch| perform(operation, request, descriptors, scratch) }
        # Through the wire format, so the result is checked and arrives as it would from a cell.
        HotCell::Response.parse(response.to_line)
      rescue HotCell::MessageError, HotCell::AccessModeError => e
        failed("invalid", e)
      rescue NoMemoryError => e
        failed(HotCell::Codes::KILLED, e, cause: HotCell::Codes::MEMORY)
      rescue StandardError => e
        failed("failed", e)
      end

      private

      def perform(operation, request, descriptors, scratch)
        inputs, outputs = descriptors.partition { |descriptor| descriptor.is_a?(HotCell::Input) }
        inputs = inputs.each_with_index.map { |input, index| HotCell::Input.new(input.to_io, scratch: -> { File.join(scratch, "input-#{index}") }) }
        outputs = outputs.each_with_index.map { |output, index| HotCell::Output.new(output.to_io, scratch: -> { File.join(scratch, "output-#{index}") }) }

        prepare(operation)
        result = operation.new.perform(inputs, outputs, **request.payload)
        written = outputs.map(&:post)
        return failed("unavailable", "an output received no bytes") if written.any?(&:zero?)

        HotCell::Response.ok(result: result)
      rescue *operation.unreadable => e
        failed("unreadable", e, cause: e.class.respond_to?(:cause) ? e.class.cause : nil)
      end

      # A cell runs each operation's before_fork hooks once, and its before_worker_boot hooks in each worker.
      def prepare(operation)
        @prepared ||= {}
        @prepared[operation] ||= (operation.before_fork + operation.before_worker_boot).each(&:call)
      end

      def failed(code, detail, cause: nil)
        HotCell::Response.failed(HotCell::Failure.for(code, detail, cause: cause))
      end
    end
  end
end
