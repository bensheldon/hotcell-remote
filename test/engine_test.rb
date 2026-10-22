# frozen_string_literal: true

require "test_helper"
require "open3"

class EngineTest < ActiveSupport::TestCase
  test "runs operations in process in the test environment, without a URL" do
    assert HotcellRemote.inline
    assert_nil HotcellRemote.url
    assert_instance_of HotcellRemote::Transports::Rack, HotcellRemote.transport
  end

  test "never loads or runs operations in process in production" do
    script = <<~RUBY
      require_relative "test/dummy/config/environment"
      print HotcellRemote.operations.size, " "
      begin
        HotcellRemote.perform("text.count", StringIO.new("abc"))
      rescue HotcellRemote::ConfigurationError
        print "refused"
      end
    RUBY
    output, status = Open3.capture2e({ "RAILS_ENV" => "production" }, "ruby", "-Ilib", "-e", script, chdir: File.expand_path("..", __dir__))

    assert status.success?, output
    assert_equal "0 refused", output
  end
end
