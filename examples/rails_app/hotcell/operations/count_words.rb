# frozen_string_literal: true

class CountWordsOperation < HotCell::Operation
  operation "text.count_words"

  def perform(inputs, _outputs)
    { words: inputs.first.to_io.each_line.sum { |line| line.split.size } }
  end
end
