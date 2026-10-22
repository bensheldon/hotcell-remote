# syntax = docker/dockerfile:1
# The image for the hotcell-remote service. Build it from the application's root, so it can install the
# application's Gemfile.lock:
#
#   docker build -f hotcell/Dockerfile -t hotcell-remote .
#
# The service is one process tree: Puma runs the gateway, and the gateway starts the Hot Cell as a child
# process. It listens on $PORT.

ARG RUBY_VERSION=3.4
FROM docker.io/library/ruby:$RUBY_VERSION-slim AS base

# The tools that your operations run, and nothing else.
RUN apt-get update -qq && \
    apt-get upgrade -y --no-install-recommends && \
    apt-get install -y --no-install-recommends libvips42t64 poppler-utils && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

# BUNDLE_ONLY installs just the Gemfile's hotcell group: no Rails, and none of the application's other gems.
# OMP_NUM_THREADS should match the container's CPUs.
ENV BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_ONLY="hotcell" \
    HOME=/tmp \
    PORT=8080 \
    OMP_NUM_THREADS=1 \
    OMP_THREAD_LIMIT=4

WORKDIR /app


FROM base AS build

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential git pkg-config

COPY .ruby-version Gemfile Gemfile.lock ./
RUN bundle install && \
    rm -rf "${BUNDLE_PATH}"/ruby/*/cache "${BUNDLE_PATH}"/ruby/*/bundler/gems/*/.git


FROM base

COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /app /app
COPY hotcell/ /app/hotcell/

# The service runs as an unprivileged user that owns none of its code, so a worker can't change what the
# next boot loads.
RUN useradd --uid 10001 --user-group --no-create-home --shell /usr/sbin/nologin hotcell && \
    chown -R root:root /app && chmod -R go-w /app && \
    find / -xdev -type f -perm /06000 -exec chmod a-s {} +

USER 10001:10001

# -w 0 keeps Puma in single mode, so one gateway starts one cell. The port comes from $PORT, which Heroku sets
# for each dyno.
CMD ["sh", "-c", "exec bundle exec puma -w 0 -p \"${PORT:-8080}\" hotcell/config.ru"]
