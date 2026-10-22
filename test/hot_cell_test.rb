# frozen_string_literal: true

require "test_helper"
require "hotcell_remote/service"
require "tmpdir"

# Starts the service, a gateway and its Hot Cell, and calls the cell through the gateway.
class HotCellTest < ActiveSupport::TestCase
  setup do
    skip "Hot Cell runs on Linux" unless RUBY_PLATFORM.include?("linux")

    @neighbor = File.join(Dir.tmpdir, "hotcell-remote-neighbor-#{Process.pid}")
    File.write(@neighbor, "")
    @gateway = with_env("HOTCELL_OPERATIONS" => File.expand_path("fixtures/operations", __dir__)) do
      Rack::MockRequest.new(HotcellRemote::Service.gateway)
    end
  end

  teardown do
    HotcellRemote::Service.stop
    FileUtils.rm_f(@neighbor) if @neighbor
  end

  test "starts the cell without sweeping the shared temporary directory" do
    assert File.exist?(@neighbor)
  end

  test "stops the cell" do
    pid = HotcellRemote::Service.cell_pid
    HotcellRemote::Service.stop

    assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
  end

  test "runs operations in the cell" do
    reverse = @gateway.post("/ops/text.reverse", input: "abc", "HTTP_HOTCELL_REMOTE_PAYLOAD" => '{"times":2}')
    assert_equal [200, "cbacba", { "times" => 2 }], [reverse.status, reverse.body, JSON.parse(reverse.headers["hotcell-remote-result"])]

    count = @gateway.post("/ops/text.count", input: "abc")
    assert_equal [200, { "bytes" => 3 }], [count.status, JSON.parse(count.body)]
  end

  test "reports a failed tool as unprocessable" do
    response = @gateway.post("/ops/text.fail", input: "abc")

    assert_equal 422, response.status
    assert_match(/unreadable/, JSON.parse(response.body)["error"])
  end

  private

  def with_env(values)
    original = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    original.each { |key, value| ENV[key] = value }
  end
end
