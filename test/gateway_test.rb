# frozen_string_literal: true

require "test_helper"
require "hot_cell/remote/gateway"
require "rack/mock_request"

class GatewayTest < ActiveSupport::TestCase
  def gateway(secret: nil)
    Rack::MockRequest.new(HotCell::Remote::Gateway.new(HotCell::Cell.new("cell", dir: "/nonexistent"), secret:))
  end

  test "answers health checks without the secret" do
    assert_equal 200, gateway(secret: "s3cret").get("/up").status
  end

  test "requires the secret when it has one" do
    assert_equal 401, gateway(secret: "s3cret").post("/work").status
    assert_equal 401, gateway(secret: "s3cret").post("/work", "HTTP_AUTHORIZATION" => "Bearer wrong").status
  end

  test "answers with Hot Cell's own failure when the cell is unreachable" do
    line = HotCell::Request.new(op: "text.count").to_line
    response = gateway.post("/work", params: { "request" => line })

    assert_equal 200, response.status
    assert_equal "unavailable", HotCell::Response.parse(response.body.lines.first).failure.code
    assert_equal "\n", response.body.lines.second
  end
end
