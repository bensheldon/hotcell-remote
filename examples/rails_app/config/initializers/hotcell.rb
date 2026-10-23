# frozen_string_literal: true

require "tempfile"
require "active_storage/transformers/transformer"
require "active_storage/analyzer/image_analyzer"

module HotCellClients
  class CountWords < HotCell::Client
    hotcell "media"
    operation "text.count_words"
  end

  class AnalyzeImage < HotCell::Client
    hotcell "media"
    operation "active_storage.analyzers.image.vips"
  end

  class RenderPdfPage < HotCell::Client
    hotcell "media"
    operation "active_storage.previewers.pdf.poppler"
  end

  class TransformImage < HotCell::Client
    hotcell "media"
    operation "active_storage.transformers.image.vips"
  end
end

module HotCellImages
  def self.transform(path, format:, operations: {})
    operations = operations.to_h.deep_transform_values { |value| value.is_a?(Symbol) ? value.to_s : value }
    tempfile = Tempfile.new(["hotcell", ".#{format}"], binmode: true)
    File.open(tempfile.path, "wb") do |output|
      File.open(path, "rb") { |input| HotCellClients::TransformImage.perform_in_hotcell(input, output, { format: format.to_s, operations: }) }
    end
    tempfile.rewind
    completed = true
    tempfile
  ensure
    tempfile&.close! unless completed
  end

  def self.analyze(path)
    File.open(path, "rb") { |input| HotCellClients::AnalyzeImage.perform_in_hotcell(input, []) }
  end
end

# Rails 8.1 cannot select a custom variant processor through config.active_storage.
# Install these adapters after active_storage.configs has applied its settings.
module HotCellActiveStorage
  class Transformer < ::ActiveStorage::Transformers::Transformer
    private

    def process(file, format:)
      content_type = Marcel::MimeType.for(extension: format.to_s)
      format = Marcel::Magic.new(content_type).extensions.first if ActiveStorage.web_image_content_types.include?(content_type)
      HotCellImages.transform(file.path, format:, operations: transformations)
    end
  end

  class ImageAnalyzer < ::ActiveStorage::Analyzer::ImageAnalyzer
    def self.accept?(blob)
      blob.image?
    end

    def metadata
      download_blob_to_tempfile { |file| HotCellImages.analyze(file.path) }
    rescue HotCell::PermanentFailure => e
      logger.info "Skipping image analysis: #{e.message}"
      {}
    end
  end

  # Hot Cell's client takes an input opened read-only and an output opened write-only.
  module Files
    private

    def with_input(file, &)
      File.open(file.path, "rb", &)
    end

    def output_tempfile(extension, &block)
      Tempfile.new(["hotcell", ".#{extension}"], binmode: true).tap do |tempfile|
        File.open(tempfile.path, "wb", &block)
        tempfile.rewind
      end
    end
  end

  # Draws a PDF's first page in the service, in place of the Poppler and MuPDF previewers.
  class PdfPreviewer < ActiveStorage::Previewer
    include Files

    def self.accept?(blob)
      Marcel::Magic.child?(blob.content_type, "application/pdf")
    end

    def preview(**)
      download_blob_to_tempfile do |file|
        image = output_tempfile("png") do |output|
          with_input(file) { |input| HotCellClients::RenderPdfPage.perform_in_hotcell(input, output, { page: 1 }) }
        end
        yield(io: image, filename: "#{blob.filename.base}.png", content_type: "image/png", **)
      ensure
        image&.close!
      end
    end
  end
end

# The cell that the hotcell-remote service runs. Requests go to HOTCELL_REMOTE_URL; in development and test,
# they run in process. The timeout covers the cell's default deadline (60s) and queue wait (10s).
HotCell::Remote.register "media", timeout: 75
