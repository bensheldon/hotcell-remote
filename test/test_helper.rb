# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "dummy/config/environment"
require "active_support/test_case"
require "minitest/autorun"
require "tempfile"

module ActiveSupport
  class TestCase
    # Yields an input holding +contents+, opened read-only, and an empty output, opened write-only, as Hot Cell's
    # client requires.
    def with_files(contents = "abc")
      Tempfile.create("input") do |input|
        input.write(contents)
        input.flush
        Tempfile.create("output") do |output|
          File.open(input.path, "rb") do |reader|
            File.open(output.path, "wb") { |writer| yield reader, writer, output.path }
          end
        end
      end
    end

    def client(cell, operation)
      Class.new(HotCell::Client) do
        hotcell cell
        operation operation
      end
    end
  end
end
