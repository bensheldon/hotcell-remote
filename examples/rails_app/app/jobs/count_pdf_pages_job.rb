# frozen_string_literal: true

# Calls the service through a Hot Cell client. The service might be busy or restarting, so retry transient
# failures; a PDF that can't be read won't get better, so discard permanent ones.
class CountPdfPagesJob < ApplicationJob
  retry_on HotCell::TransientFailure, wait: :polynomially_longer
  discard_on HotCell::PermanentFailure

  def perform(blob)
    pages = blob.open { |file| File.open(file.path, "rb") { |input| ReadPdfInfo.perform_in_hotcell(input, []) }.fetch(:pages) }
    blob.update!(metadata: blob.metadata.merge(pages:))
  end
end
