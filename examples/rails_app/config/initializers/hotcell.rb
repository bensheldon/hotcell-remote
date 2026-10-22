# frozen_string_literal: true

# The cell that the hotcell-remote service runs. Requests go to HOTCELL_REMOTE_URL; in development and test,
# they run in process. The timeout covers the cell's default deadline (60s) and queue wait (10s).
HotcellRemote.register "media", timeout: 75
