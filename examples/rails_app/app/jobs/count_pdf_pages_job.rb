# frozen_string_literal: true

# Calls an operation directly. The service might be busy or restarting, so retry transient errors; a PDF that
# can't be read won't get better, so discard permanent ones.
class CountPdfPagesJob < ApplicationJob
  retry_on HotcellRemote::TransientError, wait: :polynomially_longer
  discard_on HotcellRemote::PermanentError

  def perform(blob)
    pages = blob.open { |file| HotcellRemote.perform("pdf.info", file).result["pages"] }
    blob.update!(metadata: blob.metadata.merge(pages:))
  end
end
