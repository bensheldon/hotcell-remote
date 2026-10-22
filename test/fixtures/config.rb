# frozen_string_literal: true

require "hotcell_remote/cell"

HotCell.limits concurrency: 2, queue_size: 4, deadline: 30, memory: 1024**3
