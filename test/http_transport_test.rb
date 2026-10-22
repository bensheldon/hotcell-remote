# frozen_string_literal: true

require "test_helper"
require "puma"
require "puma/configuration"
require "puma/launcher"

class HttpTransportTest < ActiveSupport::TestCase
  setup do
    app = HotcellRemote::Gateway.new(executor: HotcellRemote::Executors::Inline.new, access_secret: "s3cret")
    @server = Puma::Server.new(app, nil, min_threads: 1, max_threads: 2, log_writer: Puma::LogWriter.null)
    @port = @server.add_tcp_listener("127.0.0.1", 0).addr[1]
    @server.run
  end

  teardown do
    @server.stop(true)
  end

  def transport(**) = HotcellRemote::Transports::Http.new("http://127.0.0.1:#{@port}", **)

  test "calls a remote gateway with the access secret" do
    assert_equal({ "bytes" => 3 }, transport(access_secret: "s3cret").perform("text.count", StringIO.new("abc"), {}).result)
    assert_equal "cba", transport(access_secret: "s3cret").perform("text.reverse", StringIO.new("abc"), {}).output
  end

  test "raises a permanent error without the access secret" do
    error = assert_raises(HotcellRemote::PermanentError) { transport.perform("text.count", StringIO.new("abc"), {}) }
    assert_equal "Unauthorized", error.message
  end

  test "raises a transient error when the gateway is unreachable" do
    @server.stop(true)

    assert_raises(HotcellRemote::TransientError) { transport.perform("text.count", StringIO.new("abc"), {}) }
  end
end
