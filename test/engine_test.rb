# frozen_string_literal: true

require "test_helper"
require "open3"

class EngineTest < ActiveSupport::TestCase
  test "runs requests in process in the test environment, without a URL" do
    assert_instance_of HotcellRemote::Transports::Inline, HotCell.cell("text").transport
  end

  test "refuses to boot in production without a URL" do
    output, status = boot_production

    assert_not status.success?
    assert_match(/HotcellRemote.url is not set/, output)
  end

  test "sends requests to the service in production, without loading the operations" do
    output, status = boot_production("HOTCELL_REMOTE_URL" => "http://hotcell-remote.test")

    assert status.success?, output
    assert_equal "HotcellRemote::Transports::Http nil", output
  end

  private

  def boot_production(env = {})
    script = <<~RUBY
      require_relative "test/dummy/config/environment"
      print HotCell.cell("text").transport.class, " ", defined?(TextOperations).inspect
    RUBY
    Open3.capture2e({ "RAILS_ENV" => "production" }.merge(env), "ruby", "-Ilib", "-e", script, chdir: File.expand_path("..", __dir__))
  end
end
