# frozen_string_literal: true

require_relative "lib/hot_cell/remote/version"

Gem::Specification.new do |spec|
  spec.name = "hotcell-remote"
  spec.version = HotCell::Remote::VERSION
  spec.summary = "Run Hot Cell operations on untrusted files from a Rails app, in process or in a separate networked service."
  spec.authors = ["Ben Sheldon"]
  spec.email = ["bensheldon@gmail.com"]
  spec.homepage = "https://github.com/bensheldon/hotcell-remote"
  spec.license = "MIT"

  spec.files = Dir["lib/**/*", "examples/**/*", "README.md", "LICENSE"]

  spec.required_ruby_version = ">= 3.3"
  spec.add_dependency "hotcell-client", ">= 1.2"
  spec.add_dependency "rack", ">= 3"
  spec.metadata["rubygems_mfa_required"] = "true"
  spec.metadata["source_code_uri"] = spec.homepage
end
