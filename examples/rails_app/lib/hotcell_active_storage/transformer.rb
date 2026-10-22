# frozen_string_literal: true

module HotcellActiveStorage
  # Generates variants in the service, in place of ActiveStorage::Transformers::Vips.
  class Transformer < ActiveStorage::Transformers::Transformer
    include Files

    private

    def process(file, format:)
      output_tempfile(format) do |output|
        with_input(file) { |input| TransformImage.perform_in_hotcell(input, output, { format: format.to_s, operations: }) }
      end
    end

    def operations
      transformations.filter_map { |name, argument| [name.to_s, argument] if argument.present? }
    end
  end
end
