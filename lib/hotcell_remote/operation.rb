# frozen_string_literal: true

require "open3"
require "tmpdir"

module HotcellRemote
  # An operation reads the file at +input+, may write the file at +output+, and returns a Hash that travels
  # as JSON. Both are paths, so an operation runs the same in process and in a Hot Cell worker, where they
  # are /dev/fd paths to the caller's descriptors.
  class Operation
    class << self
      def operation(name = nil)
        return @operation unless name

        @operation = name
        HotcellRemote.register(self)
      end

      # Declares that the operation returns only its result and writes no file.
      def result_only
        @result_only = true
      end

      def result_only? = @result_only || false

      # Checks the payload against perform's keywords before the operation is dispatched, so a bad request
      # is rejected the same way wherever the operation runs.
      def verify_payload!(payload)
        parameters = instance_method(:perform).parameters
        required = parameters.filter_map { |type, name| name.to_s if type == :keyreq }
        allowed = required + parameters.filter_map { |type, name| name.to_s if type == :key }

        missing = required - payload.keys
        raise ArgumentError, "missing keyword: #{missing.join(', ')}" if missing.any?

        unknown = payload.keys - allowed
        raise ArgumentError, "unknown keyword: #{unknown.join(', ')}" if unknown.any?
      end
    end

    # +run_tool+ replaces how tools are started; it takes the command and returns [stdout, stderr, success].
    def initialize(run_tool: nil)
      @run_tool = run_tool
    end

    def perform(input, output, **payload)
      raise NotImplementedError
    end

    private

    # Runs a tool with only the environment it needs, so nothing secret reaches a process parsing an
    # attacker's file. A tool that fails means it couldn't read the input.
    def run(*command)
      command = command.map(&:to_s)
      out, err, success = @run_tool ? @run_tool.call(command) : capture(command)
      raise UnreadableInput, "#{command.first} failed: #{err.strip}" unless success

      out
    end

    def capture(command)
      env = { "PATH" => ENV.fetch("PATH"), "HOME" => Dir.tmpdir, "LANG" => "C.UTF-8" }
      out, err, status = Open3.capture3(env, *command, unsetenv_others: true)
      [out, err, status.success?]
    end

    # Runs the block with a scratch directory, for tools that choose their own output file name, then copies
    # the file the block returns to +output+.
    def staged(output)
      Dir.mktmpdir("hotcell_remote") do |dir|
        staged_path = yield dir
        raise UnreadableInput, "no output was produced" unless File.exist?(staged_path)

        File.open(output, "wb") { |file| File.open(staged_path, "rb") { |source| IO.copy_stream(source, file) } }
      end
    end
  end
end
