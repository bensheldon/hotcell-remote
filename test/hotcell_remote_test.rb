# frozen_string_literal: true

require "test_helper"

# In test, requests run in process, through the same Hot Cell clients and codes as the service.
class HotCellRemoteTest < ActiveSupport::TestCase
  test "reports supervisor diagnostics as unsupported when running inline" do
    cell = HotCell.cell("text")
    response = cell.transport.call(cell, HotCell::Request.new(op: HotCell::METRICS).to_line, [], socket: cell.control_socket)

    assert_equal "unsupported", response.failure.code
  end

  test "runs an operation that writes an output" do
    with_files do |input, output, output_path|
      assert_equal({ times: 2 }, client("text", "text.reverse").perform_in_hotcell(input, output, { times: 2 }))
      assert_equal "cbacba", File.read(output_path)
    end
  end

  test "runs an operation that only returns a result, with a tool" do
    with_files do |input|
      assert_equal({ bytes: 3 }, client("text", "text.count").perform_in_hotcell(input, []))
    end
  end

  test "raises a permanent failure for an unreadable input" do
    with_files do |input|
      error = assert_raises(HotCell::PermanentFailure) { client("text", "text.unreadable").perform_in_hotcell(input, []) }
      assert_equal "unreadable", error.hot_cell_failure.code
    end
  end

  # Transient, as in Hot Cell: an operation that the cell doesn't have yet usually means a deploy in progress.
  test "raises a transient failure for an unknown operation" do
    with_files do |input|
      error = assert_raises(HotCell::TransientFailure) { client("text", "text.unknown").perform_in_hotcell(input, []) }
      assert_equal "unsupported", error.hot_cell_failure.code
    end
  end
end
