# frozen_string_literal: true

module HotcellActiveStorage
  # Draws a PDF's first page in the service, in place of the Poppler and MuPDF previewers.
  class PdfPreviewer < ActiveStorage::Previewer
    include Files

    def self.accept?(blob)
      Marcel::Magic.child?(blob.content_type, "application/pdf")
    end

    def preview(**)
      download_blob_to_tempfile do |file|
        image = output_tempfile("png") do |output|
          with_input(file) { |input| RenderPdfPage.perform_in_hotcell(input, output, { page: 1 }) }
        end
        yield(io: image, filename: "#{blob.filename.base}.png", content_type: "image/png", **)
      ensure
        image&.close!
      end
    end
  end
end
