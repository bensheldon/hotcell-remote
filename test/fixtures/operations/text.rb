# frozen_string_literal: true

module TextOperations
  # Writes the input reversed, repeated +times+.
  class Reverse < HotCell::Operation
    operation "text.reverse"

    def perform(inputs, outputs, times: 1)
      File.binwrite(outputs.first.fd_path, File.binread(inputs.first.fd_path).reverse * times)
      { times: }
    end
  end

  # Counts the input's bytes with a tool, which receives the input's descriptor.
  class Count < HotCell::Operation
    operation "text.count"

    def perform(inputs, _outputs)
      result = run_tool("wc", "-c", inputs.first.fd_path, pass: [inputs.first.to_io])
      { bytes: Integer(result.out.split.first) }
    end
  end

  class Unreadable < HotCell::Operation
    operation "text.unreadable"

    def perform(_inputs, _outputs)
      raise HotCell::UnreadableInput, "not text"
    end
  end
end
