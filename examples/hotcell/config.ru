# frozen_string_literal: true

require "hotcell_remote"
require "hotcell_remote/executors/hot_cell"

HotCell.root = ENV.fetch("HOTCELL_ROOT")
HotCell.group = ENV.fetch("HOTCELL_GROUP", nil)
HotcellRemote.load_operations(ENV.fetch("HOTCELL_OPERATIONS"))

run HotcellRemote::Gateway.new(executor: HotcellRemote::Executors::HotCell.new, access_secret: ENV.fetch("HOTCELL_ACCESS_SECRET", nil))
