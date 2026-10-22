# frozen_string_literal: true

require "test_helper"
require "rack/mock_request"

class GatewayTest < ActiveSupport::TestCase
  def gateway(**) = Rack::MockRequest.new(HotcellRemote::Gateway.new(executor: HotcellRemote::Executors::Inline.new, **))

  test "answers health checks without the access secret" do
    assert_equal 200, gateway(access_secret: "s3cret").get("/up").status
  end

  test "requires the access secret when it has one" do
    assert_equal 401, gateway(access_secret: "s3cret").post("/ops/text.count", input: "abc").status
    assert_equal 401, gateway(access_secret: "s3cret").post("/ops/text.count", input: "abc", "HTTP_AUTHORIZATION" => "Bearer wrong").status
    assert_equal 200, gateway(access_secret: "s3cret").post("/ops/text.count", input: "abc", "HTTP_AUTHORIZATION" => "Bearer s3cret").status
  end

  test "rejects a payload that is not a JSON object" do
    response = gateway.post("/ops/text.reverse", input: "abc", "HTTP_HOTCELL_REMOTE_PAYLOAD" => "[1]")

    assert_equal 400, response.status
  end
end
