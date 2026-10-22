# frozen_string_literal: true

# Generate variants, analyze images, and preview PDFs with hotcell_remote operations instead of in
# process. Video and audio stay with Active Storage's analyzers and previewer.
Rails.application.config.hotcell_remote.active_storage.tap do |active_storage|
  active_storage.variant_transformer = "HotcellActiveStorage::Transformer"
  active_storage.analyzers = %w[
    HotcellActiveStorage::ImageAnalyzer
    ActiveStorage::Analyzer::VideoAnalyzer
    ActiveStorage::Analyzer::AudioAnalyzer
  ]
  active_storage.previewers = %w[
    HotcellActiveStorage::PdfPreviewer
    ActiveStorage::Previewer::VideoPreviewer
  ]
end
