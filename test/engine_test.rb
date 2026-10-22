# frozen_string_literal: true

require "test_helper"

class EngineTest < ActiveSupport::TestCase
  test "loads the application's operations at boot" do
    assert_equal TextOperations::Reverse, HotcellRemote.operations["text.reverse"]
  end

  test "runs operations in process in the test environment, without a URL" do
    assert HotcellRemote.allow_inline
    assert_nil HotcellRemote.url
    assert_instance_of HotcellRemote::Transports::Rack, HotcellRemote.transport
  end
end
