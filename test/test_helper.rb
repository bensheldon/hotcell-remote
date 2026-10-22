# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"
require_relative "dummy/config/environment"
require "active_support/test_case"
require "minitest/autorun"
require "stringio"

HotcellRemote.load_operations(HotcellRemote.operations_path)
