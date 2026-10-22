# frozen_string_literal: true

require "test_helper"
require "hotcell_remote/service"
require "tmpdir"

# Boots a real Hot Cell with hotcell-remote-cell and calls it through the service's gateway.
class HotCellTest < ActiveSupport::TestCase
  setup do
    skip "Hot Cell runs on Linux" unless RUBY_PLATFORM.include?("linux")

    # A Unix socket path must fit in 108 bytes. With no TMPDIR, the cell gets a temporary directory of its
    # own to sweep, rather than /tmp, which holds this test's files.
    @root = Dir.mktmpdir("hc", "/tmp")
    @neighbor = File.join(@root, "neighbor")
    File.write(@neighbor, "")
    env = {
      "HOTCELL_DIR" => File.join(@root, HotcellRemote::Executors::HotCell::CELL),
      "TMPDIR" => nil,
      "TMP" => nil,
      "TEMP" => nil,
      "HOTCELL_OPERATIONS" => File.expand_path("fixtures/operations", __dir__),
      "RUBYLIB" => File.expand_path("../lib", __dir__)
    }
    @log = File.join(@root, "cell.log")
    @pid = Process.spawn(env, "bundle", "exec", "hotcell-remote-cell", out: @log, err: @log, pgroup: true)
    wait_for_socket(File.join(env["HOTCELL_DIR"], "work.sock"))

    @gateway = with_env("HOTCELL_ROOT" => @root, "HOTCELL_OPERATIONS" => File.expand_path("fixtures/operations", __dir__)) do
      Rack::MockRequest.new(HotcellRemote::Service.gateway)
    end
  end

  teardown do
    Process.kill("TERM", -@pid) if @pid
    Process.wait(@pid) if @pid
    FileUtils.rm_rf(@root) if @root
  end

  test "boots without sweeping the shared temporary directory" do
    assert File.exist?(@neighbor)
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

  def wait_for_socket(path)
    deadline = Time.now + 30
    sleep 0.1 until File.socket?(path) || Time.now > deadline
    flunk "the cell didn't start:\n#{File.read(@log)}" unless File.socket?(path)
  end
end
