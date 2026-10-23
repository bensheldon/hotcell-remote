# frozen_string_literal: true

require "test_helper"

class DefaultOperationsTest < ActiveSupport::TestCase
  test "renders a PDF with the upstream Poppler operation" do
    Tempfile.create(["preview", ".png"], binmode: true) do |image|
      File.open(image.path, "wb") do |output|
        file_fixture("two-pages.pdf").open("rb") { |input| HotCellClients::RenderPdfPage.perform_in_hotcell(input, output) }
      end

      assert_equal "\x89PNG\r\n\x1a\n".b, image.read(8)
    end
  end
end
