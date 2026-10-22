# syntax = docker/dockerfile:1
# The image for a hotcell-remote service. Build it from the application's root, so it can install the
# application's Gemfile.lock:
#
#   docker build -f hotcell/Dockerfile -t hotcell-remote .
#
# One image runs as two containers that share a volume at /run/hotcell:
#   - cell (the default command): the Hot Cell supervisor and the forked workers that parse untrusted files.
#   - gateway (`bundle exec puma --port 8080 config.ru`): the HTTP API the application calls. It passes each
#     request to the cell over the cell's UNIX socket.

ARG RUBY_VERSION=3.4
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# The tools your operations run, and nothing else.
RUN apt-get update -qq && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends libvips42t64 poppler-utils && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# BUNDLE_ONLY installs just the Gemfile's hotcell group: no Rails, and none of the application's gems.
# OMP_NUM_THREADS should match the container's CPUs.
ENV BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_ONLY="hotcell" \
    HOME=/tmp \
    OMP_NUM_THREADS=1 \
    OMP_THREAD_LIMIT=4 \
    HOTCELL_OPERATIONS=/hotcell/operations \
    HOTCELL_ROOT=/run/hotcell \
    HOTCELL_DIR=/run/hotcell/hotcell_remote \
    HOTCELL_GROUP=10001

WORKDIR /hotcell


FROM base AS build

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential git pkg-config

COPY .ruby-version Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git


FROM base

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /hotcell /hotcell
COPY hotcell/config.rb hotcell/config.ru /hotcell/
COPY hotcell/operations /hotcell/operations

# The cell runs as 10001:10001. The gateway runs as 10002 in group 10001: the group lets it reach the cell's
# 0660 sockets and share each request's files with the cell, without sharing a uid with it. The cell's code
# belongs to root, so a worker can't change what the next boot loads.
RUN groupadd --gid 10001 hotcell && \
    useradd --uid 10001 --gid 10001 --no-create-home --shell /usr/sbin/nologin hotcell && \
    useradd --uid 10002 --gid 10001 --no-create-home --shell /usr/sbin/nologin gateway && \
    mkdir -p /run/hotcell/hotcell_remote && chown -R hotcell:hotcell /run/hotcell && chmod 0770 /run/hotcell/hotcell_remote && \
    chown -R root:root /hotcell && chmod -R go-w /hotcell && \
    find / -xdev -type f -perm /06000 -exec chmod a-s {} +

USER 10001:10001

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD ["bundle", "exec", "hotcell-health"]

CMD ["bundle", "exec", "hotcell"]
