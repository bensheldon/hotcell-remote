# syntax = docker/dockerfile:1
# The application's image. It leaves out the hotcell group, and installs none of the tools that the operations
# run, such as libvips or poppler: the application only sends files to the service.

ARG RUBY_VERSION=3.4
FROM docker.io/library/ruby:$RUBY_VERSION-slim

ENV RAILS_ENV="production" \
    BUNDLE_DEPLOYMENT="1" \
    BUNDLE_PATH="/usr/local/bundle" \
    BUNDLE_WITHOUT="development:test:hotcell"

WORKDIR /rails

RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends build-essential git libsqlite3-0 && \
    rm -rf /var/lib/apt/lists /var/cache/apt/archives

COPY .ruby-version Gemfile Gemfile.lock ./
RUN bundle install

COPY . .

CMD ["bundle", "exec", "puma"]
