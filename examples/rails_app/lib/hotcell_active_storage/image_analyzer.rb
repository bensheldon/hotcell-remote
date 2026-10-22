# frozen_string_literal: true

module HotcellActiveStorage
  # Reads image dimensions in the service, in place of the Vips image analyzer.
  class ImageAnalyzer < ActiveStorage::Analyzer::ImageAnalyzer
    include Files

    def self.accept?(blob)
      blob.image?
    end

    def metadata
      download_blob_to_tempfile { |file| with_input(file) { |input| AnalyzeImage.perform_in_hotcell(input, []) } }
    rescue HotCell::PermanentFailure => e
      logger.info "Skipping image analysis: #{e.message}"
      {}
    end
  end
end
