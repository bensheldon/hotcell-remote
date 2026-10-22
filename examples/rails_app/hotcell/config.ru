# frozen_string_literal: true

require "hot_cell/remote/service"

# Every request must send this secret, which the application sends from its own HOTCELL_REMOTE_SECRET.
run HotCell::Remote::Service.gateway(secret: ENV.fetch("HOTCELL_REMOTE_SECRET"))
