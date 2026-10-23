# frozen_string_literal: true

require "test_helper"

class CountWordsTest < ActiveSupport::TestCase
  test "counts words through a custom Hot Cell operation" do
    Tempfile.create("words") do |file|
      file.write("one two\nthree\n")
      file.flush

      result = File.open(file.path, "rb") { |input| HotCellClients::CountWords.perform_in_hotcell(input, []) }
      assert_equal({ words: 3 }, result)
    end
  end
end
