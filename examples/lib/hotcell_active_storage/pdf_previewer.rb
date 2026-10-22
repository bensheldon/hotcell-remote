# frozen_string_literal: true

module HotcellActiveStorage
  # Draws a PDF's first page with the pdf.render_page operation, in place of the Poppler and MuPDF previewers.
  class PdfPreviewer < ActiveStorage::Previewer
    def self.accept?(blob)
      Marcel::Magic.child?(blob.content_type, "application/pdf")
    end

    def preview(**)
      download_blob_to_tempfile do |input|
        response = HotcellRemote.perform("pdf.render_page", input, page: 1, resolution: 72, format: "png")
        yield(io: StringIO.new(response.output), filename: "#{blob.filename.base}.png", content_type: "image/png", **)
      end
    end
  end
end
