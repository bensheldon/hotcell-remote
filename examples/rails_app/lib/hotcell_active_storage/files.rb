# frozen_string_literal: true

module HotcellActiveStorage
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
end
