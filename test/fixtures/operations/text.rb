# frozen_string_literal: true

module TextOperations
  # Writes the input reversed, repeated +times+.
  class Reverse < HotcellRemote::Operation
    operation "text.reverse"

    def perform(input, output, times: 1)
      File.binwrite(output, File.binread(input).reverse * times)
      { times: }
    end
  end

  # Counts the input's bytes with a tool, which must be able to read the input's path.
  class Count < HotcellRemote::Operation
    operation "text.count"
    result_only

    def perform(input, _output)
      { bytes: Integer(run("wc", "-c", input).split.first) }
    end
  end

  class Fail < HotcellRemote::Operation
    operation "text.fail"
    result_only

    def perform(_input, _output)
      run("false")
    end
  end
end
