# frozen_string_literal: true

module HotcellActiveStorage
  # Generates variants with the image.transform operation, in place of ActiveStorage::Transformers::Vips.
  class Transformer < ActiveStorage::Transformers::Transformer
    private

    def process(file, format:)
      response = HotcellRemote.perform("image.transform", file, format: format.to_s, operations: operations)
      Tempfile.new(["hotcell_remote", ".#{format}"], binmode: true).tap do |tempfile|
        tempfile.write(response.output)
        tempfile.rewind
      end
    end

    def operations
      transformations.filter_map { |name, argument| [name.to_s, argument] if argument.present? }
    end
  end
end
