# frozen_string_literal: true

require "test_helper"

# In test, operations run in process, through the same gateway as the service's.
class PdfOperationsTest < ActiveSupport::TestCase
  test "reads the page count" do
    response = file_fixture("two-pages.pdf").open { |file| HotcellRemote.perform("pdf.info", file) }

    assert_equal 2, response.result["pages"]
  end

  test "raises a permanent error for a file that isn't a PDF" do
    assert_raises(HotcellRemote::PermanentError) { HotcellRemote.perform("pdf.info", StringIO.new("not a PDF")) }
  end
end
