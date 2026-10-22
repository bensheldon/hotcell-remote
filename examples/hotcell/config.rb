# frozen_string_literal: true

require "hotcell_remote/cell"

# deadline is seconds; memory is bytes.
HotCell.limits concurrency: 2, queue_size: 8, deadline: 60, memory: 1024**3
