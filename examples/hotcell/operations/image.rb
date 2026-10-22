# frozen_string_literal: true

require "image_processing/vips"

module ImageOperations
  # Converts to +format+ and applies ImageProcessing operations, given as a Hash or as [name, argument]
  # pairs, e.g. { "resize_to_limit" => [800, 600], "saver" => { "quality" => 80 } }.
  class Transform < HotcellRemote::Operation
    operation "image.transform"

    def perform(input, output, format:, operations: [])
      staged(output) do |dir|
        File.join(dir, "image.#{format}").tap do |destination|
          ImageProcessing::Vips.source(input).loader(page: 0).convert(format).apply(symbolize_keys(operations.to_a)).call(destination:)
        end
      end

      { content_type: "image/#{format}" }
    rescue Vips::Error => e
      raise HotcellRemote::UnreadableInput, e.message
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
  class Analyze < HotcellRemote::Operation
    operation "image.analyze"
    result_only

    ROTATIONS = /Right-top|Left-bottom|Top-right|Bottom-left/

    def perform(input, _output)
      image = Vips::Image.new_from_file(input, access: :sequential)

      rotated?(image) ? { width: image.height, height: image.width } : { width: image.width, height: image.height }
    rescue Vips::Error => e
      raise HotcellRemote::UnreadableInput, e.message
    end

    private

    def rotated?(image)
      ROTATIONS.match?(image.get("exif-ifd0-Orientation"))
    rescue Vips::Error
      false
    end
  end
end
