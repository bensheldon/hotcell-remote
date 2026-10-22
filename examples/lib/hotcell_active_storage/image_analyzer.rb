# frozen_string_literal: true

module HotcellActiveStorage
  # Reads image dimensions with the image.analyze operation, in place of the Vips image analyzer.
  class ImageAnalyzer < ActiveStorage::Analyzer::ImageAnalyzer
    def self.accept?(blob)
      blob.image?
    end

    def metadata
      download_blob_to_tempfile do |file|
        HotcellRemote.perform("image.analyze", file).result.symbolize_keys
      end
    rescue HotcellRemote::PermanentError => e
      logger.info "Skipping image analysis: #{e.message}"
      {}
    end
  end
end
