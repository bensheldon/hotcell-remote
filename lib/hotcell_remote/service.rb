# frozen_string_literal: true

require "English"
require "fileutils"
require "rbconfig"
require "tmpdir"
require "hotcell_remote"
require "hotcell_remote/executors/hot_cell"

module HotcellRemote
  # The service: a gateway and the Hot Cell that it starts, together in one process tree, so the service
  # deploys as one unit, such as a Heroku dyno or a single container. The cell runs as a child process, never
  # inside the gateway's, with its sockets and its scratch in private temporary directories.
  #
  # The operations are in hotcell/operations, relative to the working directory, as they are in the
  # application. If hotcell/config.rb exists, the cell loads it, for example to change HotCell.limits.
  module Service
    OPERATIONS = "hotcell/operations"
    CELL_CONFIG = "hotcell/config.rb"
    BOOT_TIMEOUT = 30

    class << self
      attr_reader :cell_pid

      # Starts the cell and returns the gateway, a Rack app that passes each request to it.
      def gateway
        operations = File.expand_path(ENV.fetch("HOTCELL_OPERATIONS", OPERATIONS))
        ::HotCell.root = start_cell(operations)
        HotcellRemote.load_operations(operations)

        Gateway.new(executor: Executors::HotCell.new, access_secret: ENV.fetch("HOTCELL_REMOTE_SECRET", nil))
      end

      def stop
        return unless @cell_pid

        @stopping = true
        Process.kill("TERM", @cell_pid)
        Process.kill("KILL", @cell_pid) unless @monitor.join(10)
      rescue Errno::ESRCH
        nil
      ensure
        FileUtils.rm_rf(@root) if @root
        @cell_pid = @root = nil
      end

      private

      def start_cell(operations)
        @root = Dir.mktmpdir("hotcell-remote")
        sockets = File.join(@root, Executors::HotCell::CELL)
        scratch = FileUtils.mkdir_p(File.join(@root, "scratch")).first
        env = {
          "HOTCELL_DIR" => sockets,
          "HOTCELL_OPERATIONS" => operations,
          "HOTCELL_CONFIG" => File.expand_path(CELL_CONFIG),
          "TMPDIR" => scratch
        }
        @stopping = false
        @cell_pid = Process.spawn(env, RbConfig.ruby, "-rbundler/setup", Gem.bin_path("hotcell-remote", "hotcell-remote-cell"))
        wait_for_cell(File.join(sockets, "work.sock"))
        monitor_cell
        at_exit { stop }
        @root
      end

      def wait_for_cell(socket)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BOOT_TIMEOUT
        until File.socket?(socket)
          raise Error, "the cell exited while it booted: #{$CHILD_STATUS}" if Process.waitpid(@cell_pid, Process::WNOHANG)
          raise Error, "the cell didn't boot in #{BOOT_TIMEOUT} seconds" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.05
        end
      end

      # The gateway can't serve without its cell, so when the cell exits, stop the gateway too, and let the
      # platform restart the whole service.
      def monitor_cell
        pid = @cell_pid
        @monitor = Thread.new do
          Process.wait(pid)
          unless @stopping
            warn "hotcell-remote: the cell exited (#{$CHILD_STATUS}), so the gateway is stopping"
            Process.kill("TERM", Process.pid)
          end
        end
      end
    end
  end
end
