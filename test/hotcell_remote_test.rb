# frozen_string_literal: true

require "test_helper"

class HotcellRemoteTest < ActiveSupport::TestCase
  def input = StringIO.new("abc")

  test "returns the file an operation writes, with its result" do
    response = HotcellRemote.perform("text.reverse", input, times: 2)

    assert_equal "cbacba", response.output
    assert_equal({ "times" => 2 }, response.result)
  end

  test "returns only the result of a result-only operation" do
    response = HotcellRemote.perform("text.count", input)

    assert_nil response.output
    assert_equal({ "bytes" => 3 }, response.result)
  end

  test "raises a permanent error when a tool fails" do
    error = assert_raises(HotcellRemote::PermanentError) { HotcellRemote.perform("text.fail", input) }
    assert_match(/false failed/, error.message)
  end

  test "raises a permanent error for a bad argument" do
    error = assert_raises(HotcellRemote::PermanentError) { HotcellRemote.perform("text.reverse", input, size: 2) }
    assert_equal "unknown keyword: size", error.message
  end

  test "raises a permanent error for an unknown operation" do
    error = assert_raises(HotcellRemote::PermanentError) { HotcellRemote.perform("text.unknown", input) }
    assert_equal "Unknown operation text.unknown", error.message
  end

  test "calls registration callbacks for operations defined before and after" do
    registered = []
    callback = ->(operation) { registered << operation.operation }
    HotcellRemote.on_register(&callback)
    later = Class.new(HotcellRemote::Operation) { operation "text.later" }

    assert_includes registered, "text.reverse"
    assert_includes registered, "text.later"
  ensure
    HotcellRemote.registration_callbacks.delete(callback)
    HotcellRemote.operations.delete(later.operation) if later
  end

  test "refuses to run in process unless allowed" do
    original = HotcellRemote.transport
    HotcellRemote.transport = nil
    HotcellRemote.inline = false

    assert_raises(HotcellRemote::ConfigurationError) { HotcellRemote.perform("text.count", input) }
  ensure
    HotcellRemote.inline = true
    HotcellRemote.transport = original
  end
end
