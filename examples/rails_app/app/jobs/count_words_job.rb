# frozen_string_literal: true

class CountWordsJob < ApplicationJob
  retry_on HotCell::TransientFailure, wait: :polynomially_longer
  discard_on HotCell::PermanentFailure

  def perform(blob)
    words = blob.open { |file| File.open(file.path, "rb") { |input| HotCellClients::CountWords.perform_in_hotcell(input, []) }.fetch(:words) }
    blob.update!(metadata: blob.metadata.merge(words:))
  end
end
