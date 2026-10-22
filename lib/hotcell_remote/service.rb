# frozen_string_literal: true

require "hotcell_remote"
require "hotcell_remote/executors/hot_cell"

module HotcellRemote
  # The service's gateway, configured by convention. It uses Hot Cell's own defaults: the cell's sockets in
  # /run/hotcell/cell and the operations in /hotcell/operations. The gateway runs with the cell's group as its
  # primary group, which lets it reach the cell's sockets and share each request's files with the cell.
  module Service
    def self.gateway
      ::HotCell.root = ENV.fetch("HOTCELL_ROOT", "/run/hotcell")
      ::HotCell.group = ENV.fetch("HOTCELL_GROUP", Process.gid)
      HotcellRemote.load_operations(ENV.fetch("HOTCELL_OPERATIONS", "/hotcell/operations"))

      Gateway.new(executor: Executors::HotCell.new, access_secret: ENV.fetch("HOTCELL_REMOTE_SECRET", nil))
    end
  end
end
