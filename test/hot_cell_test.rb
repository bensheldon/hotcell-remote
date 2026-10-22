# frozen_string_literal: true

require "test_helper"
require "hotcell_remote/service"
require "hotcell_remote/transports/http"
require "puma"
require "tmpdir"

# Starts the service, a gateway and its Hot Cell, behind Puma, and calls it over HTTP with Hot Cell's clients.
class HotCellTest < ActiveSupport::TestCase
  setup do
    skip "Hot Cell runs on Linux" unless RUBY_PLATFORM.include?("linux")

    @neighbor = File.join(Dir.tmpdir, "hotcell-remote-neighbor-#{Process.pid}")
    File.write(@neighbor, "")

    original = ENV.fetch("HOTCELL_OPERATIONS", nil)
    ENV["HOTCELL_OPERATIONS"] = File.expand_path("fixtures/operations", __dir__)
    gateway = HotcellRemote::Service.gateway(secret: "s3cret", keepalive: 0.2)
    ENV["HOTCELL_OPERATIONS"] = original

    @server = Puma::Server.new(gateway, nil, min_threads: 1, max_threads: 2, log_writer: Puma::LogWriter.null)
    url = "http://127.0.0.1:#{@server.add_tcp_listener('127.0.0.1', 0).addr[1]}"
    @server.run
    @url = url

    HotCell.register "remote", dir: "/hotcell-remote/remote", transport: HotcellRemote::Transports::Http.new(url, secret: "s3cret")
    HotCell.register "wrong-secret", dir: "/hotcell-remote/wrong-secret", transport: HotcellRemote::Transports::Http.new(url, secret: "wrong")
  end

  teardown do
    @server&.stop(true)
    HotcellRemote::Service.stop
    FileUtils.rm_f(@neighbor) if @neighbor
  end

  test "runs operations in the cell" do
    with_files do |input, output, output_path|
      assert_equal({ times: 2 }, client("remote", "text.reverse").perform_in_hotcell(input, output, { times: 2 }))
      assert_equal "cbacba", File.read(output_path)
    end

    with_files do |input|
      assert_equal({ bytes: 3 }, client("remote", "text.count").perform_in_hotcell(input, []))
    end
  end

  test "answers with the cell's own failures" do
    with_files do |input|
      error = assert_raises(HotCell::PermanentFailure) { client("remote", "text.unreadable").perform_in_hotcell(input, []) }
      assert_equal "unreadable", error.hot_cell_failure.code
    end
  end

  test "sends newlines while the cell works, and then the answer" do
    with_files do |input|
      assert_equal({ waited: 1 }, client("remote", "text.wait").perform_in_hotcell(input, [], { seconds: 1 }))
    end

    request = Net::HTTP::Post.new(URI.join(@url, "/work"))
    request["Authorization"] = "Bearer s3cret"
    request.set_form([["request", HotCell::Request.new(op: "text.wait", payload: { seconds: 1 }).to_line]], "multipart/form-data")
    body = Net::HTTP.start(URI(@url).host, URI(@url).port) { |http| http.request(request).body }

    assert_match(/\A\n{3,}\{/, body)
  end

  test "relays control requests" do
    assert_includes HotCell.cell("remote").describe.fetch(:operations), "text.reverse"
  end

  test "refuses a request with the wrong secret" do
    with_files do |input|
      error = assert_raises(HotCell::PermanentFailure) { client("wrong-secret", "text.count").perform_in_hotcell(input, []) }
      assert_equal "invalid", error.hot_cell_failure.code
    end
  end

  test "starts the cell without sweeping the shared temporary directory" do
    assert File.exist?(@neighbor)
  end

  test "stops the cell" do
    pid = HotcellRemote::Service.cell_pid
    HotcellRemote::Service.stop

    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end
end
