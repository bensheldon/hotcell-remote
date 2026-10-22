# frozen_string_literal: true

require "hotcell_remote/service"

# Every request must send this secret, which the application sends from its own HOTCELL_REMOTE_SECRET.
run HotcellRemote::Service.gateway(secret: ENV.fetch("HOTCELL_REMOTE_SECRET"))
