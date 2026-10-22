# frozen_string_literal: true

# Loading libvips before the cell forks is safe; evaluating an image there isn't.
require "image_processing/vips"

# An input's path is /dev/fd/N, which repeats from request to request, so libvips mustn't cache images by path.
Vips.cache_set_max(0)

module ImageOperations
  # Converts to +format+ and applies ImageProcessing operations, given as [name, argument] pairs.
  class Transform < HotCell::Operation
    operation "image.transform"
    unreadable Vips::Error

    def perform(inputs, outputs, format:, operations: [])
      staged = outputs.first.path(extension: format)
      ImageProcessing::Vips.source(inputs.first.fd_path).loader(page: 0).convert(format).apply(symbolize_keys(operations)).call(destination: staged)
      outputs.first.adopt(staged)
      {}
    end

    private

    # Keyword arguments arrive from JSON with String keys.
    def symbolize_keys(value)
      case value
      when Hash then value.to_h { |key, item| [key.to_sym, symbolize_keys(item)] }
      when Array then value.map { |item| symbolize_keys(item) }
      else value
      end
    end
  end

  # Reports the dimensions as displayed, swapping them for an image whose EXIF orientation rotates it.
  class Analyze < HotCell::Operation
    operation "image.analyze"
    unreadable Vips::Error

    ROTATIONS = /Right-top|Left-bottom|Top-right|Bottom-left/

    def perform(inputs, _outputs)
      image = Vips::Image.new_from_file(inputs.first.fd_path, access: :sequential)
      rotated = begin
        ROTATIONS.match?(image.get("exif-ifd0-Orientation"))
      rescue Vips::Error
        false
      end

      rotated ? { width: image.height, height: image.width } : { width: image.width, height: image.height }
    end
  end
end
