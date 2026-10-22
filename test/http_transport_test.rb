# frozen_string_literal: true

require "test_helper"
require "hot_cell/remote/transports/http"

class HttpTransportTest < ActiveSupport::TestCase
  test "raises a transient failure when the service is unreachable" do
    HotCell.register "unreachable", dir: "/hotcell-remote/unreachable", transport: HotCell::Remote::Transports::Http.new("http://127.0.0.1:1")

    with_files do |input|
      error = assert_raises(HotCell::TransientFailure) { client("unreachable", "text.count").perform_in_hotcell(input, []) }
      assert_equal "unavailable", error.hot_cell_failure.code
    end
  end
end
