# frozen_string_literal: true

require "test_helper"

# In test, requests run in process, through the same Hot Cell clients and codes as the service's.
class PdfOperationsTest < ActiveSupport::TestCase
  test "reads the page count" do
    result = file_fixture("two-pages.pdf").open("rb") { |input| ReadPdfInfo.perform_in_hotcell(input, []) }

    assert_equal 2, result[:pages]
  end

  test "raises a permanent failure for a file that isn't a PDF" do
    Tempfile.create("not-a-pdf") do |file|
      file.write("not a PDF")
      file.flush

      assert_raises(HotCell::PermanentFailure) { File.open(file.path, "rb") { |input| ReadPdfInfo.perform_in_hotcell(input, []) } }
    end
  end
end
