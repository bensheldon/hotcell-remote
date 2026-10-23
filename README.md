# Hot Cell Remote

Run [Hot Cell](https://github.com/basecamp/hotcell) as a network service — not a sidecar — to run operations on
untrusted files.

[Hot Cell](https://github.com/basecamp/hotcell) runs untrusted work in an unprivileged sibling container on the
same host as the application, which passes it file descriptors over a UNIX socket on a shared volume. Hot Cell
Remote instead runs the cell inside a small service of its own, with an HTTP gateway in front of it. Your
application still writes Hot Cell operations and calls them with Hot Cell clients; Hot Cell Remote is the
transport that carries each request to the service and brings the answer back.

The goal is operational simplicity: the service deploys as one unit, such as a Heroku dyno or a single
container, with no sidecars, shared volumes, or special container settings. It still isolates the parsing of
untrusted files from your application: the service has none of your application's code, secrets, credentials,
or database access. It gives up some of the protections of Hot Cell's own deployment, which are described under
[What the service gives up](#what-the-service-gives-up).

```
  Rails application                              hotcell-remote service (one dyno or container)
  ─────────────────                              ───────────────────────────────────────────────────
  TransformImage.perform_in_hotcell(…)  ──HTTP──▶  Gateway (Puma) ──UNIX socket──▶ Hot Cell
  (a HotCell::Client)                                                              └─ forked worker
                                                                                       └─ operation
```

[`examples/rails_app`](examples/rails_app) is a minimal Rails application that has every piece below in its
place: the Gemfile, the operations and clients, the service's `hotcell/` directory, both Dockerfiles, Active Storage, a job, and a test.

## Installation

Hot Cell Remote integrates with Rails through a Railtie. The container example shares the application's
Gemfile and `Gemfile.lock`. A `hotcell` group holds what only the service needs: Hot Cell's server, and the gems
that your operations use.

```ruby
# Gemfile
group :default, :hotcell do
  gem "hotcell-remote", github: "bensheldon/hotcell-remote"
  gem "puma"
end

group :hotcell do
  gem "hotcell-server"

  # Gems that your operations use, for example:
  gem "image_processing"
  gem "ruby-vips"
end
```

Hot Cell Remote depends on `hotcell-client`, which the application uses to send requests. Rails never loads the
`hotcell` group, and the application's image leaves it out, along with the tools that your operations run:

```dockerfile
ENV BUNDLE_WITHOUT="development:test:hotcell"
```

Register the cell that the service runs, in place of Hot Cell's `HotCell.register`:

```ruby
# config/initializers/hotcell.rb
HotCell::Remote.register "media", timeout: 75
```

`HotCell::Remote.register` takes the same options as `HotCell.register`, such as `timeout`, `permanent`, and
`transient`, and gives the cell Hot Cell Remote's transport, which sends each request to `HOTCELL_REMOTE_URL`.

## Operations and clients

Hot Cell Remote uses Hot Cell's own operations and clients, so
[Hot Cell's documentation](https://basecamp.github.io/hotcell/) describes how to write them: the
[operation API](https://basecamp.github.io/hotcell/operation-api/) for the cell's side, and the
[client API](https://basecamp.github.io/hotcell/client-api/) for the application's side.

Use upstream operations for standard image processing, analysis, and previews. Write an operation only for
work those do not provide. The example includes a small custom operation that counts words:

```ruby
# hotcell/operations/count_words.rb
class CountWordsOperation < HotCell::Operation
  operation "text.count_words"

  def perform(inputs, _outputs)
    { words: inputs.first.to_io.each_line.sum { |line| line.split.size } }
  end
end
```

Its client is declared alongside the application's other Hot Cell settings:

```ruby
# config/initializers/hotcell.rb
module HotCellClients
  class CountWords < HotCell::Client
    hotcell "media"
    operation "text.count_words"
  end
end

File.open(path, "rb") { |input| HotCellClients::CountWords.perform_in_hotcell(input, []) } # => { words: 3 }
```

The Gemfile installs dependencies; it does not load operations. The example keeps upstream requires in
`hotcell/operations/default.rb` and its custom operation in `hotcell/operations/count_words.rb`. Hot Cell's executable uses `bundler/setup` to
make the gems available, then loads `hotcell/config.rb` and every Ruby file under `hotcell/operations/`.
A custom operation is defined in that directory. For upstream operations, a file there requires the selected
implementations from the installed gem. This keeps unused backends and their tools out of the worker's boot.

A client opens its inputs read-only and its outputs write-only, as Hot Cell requires. Failures arrive as Hot
Cell's own: `HotCell::PermanentFailure` when retrying won't help, such as an unreadable input, and
`HotCell::TransientFailure` when it may, such as an unreachable or busy service. Let Active Job retry transient
failures, and discard or record permanent ones.

## Application settings

These configure the Rails application. The service has no settings of its own except `HOTCELL_REMOTE_SECRET`,
which [`config.ru`](#deploying-the-hot-cell-remote-service) passes in.

| Setting | Default | Description |
| --- | --- | --- |
| `config.hotcell_remote.url` | `ENV["HOTCELL_REMOTE_URL"]` | The service's URL. |
| `config.hotcell_remote.secret` | `ENV["HOTCELL_REMOTE_SECRET"]` | The shared secret that the application sends as `Authorization: Bearer …`. It must match the service's. |
| `config.hotcell_remote.operations_path` | `hotcell/operations` | The directory of operation files, for [development and test parity](#development-and-test-parity). |

Without a URL, outside development and test, `HotCell::Remote.register` raises `HotCell::Remote::ConfigurationError`,
so the application doesn't boot.

## Active Storage

Hot Cell Remote only carries requests. Image transformation, image analysis, and PDF rendering come from
upstream's `activestorage-hotcell-server`; applications load the operations they need:

```ruby
# hotcell/operations/default.rb
require "active_storage/hot_cell/server/transformers/image/vips"
require "active_storage/hot_cell/server/analyzers/image/vips"
require "active_storage/hot_cell/server/previewers/pdf/poppler"
```

Add `activestorage-hotcell-server` to the cell's bundle and install libvips and Poppler in its environment.
HCR does not define image clients, media operations, or Rails compatibility adapters.

Upstream's `activestorage-hotcell-client` requires Rails 8.2. On Rails 8.1, the example keeps thin client
bindings and adapters in [its Hot Cell initializer](examples/rails_app/config/initializers/hotcell.rb). Those
bindings use upstream's operation names and payloads; they do not implement image processing. Custom PDF
page counting and extraction are application operations because upstream's previewer does not provide them.

Configure Active Storage in `config/application.rb`, applying adapters after Rails' defaults:

```ruby
config.active_storage.variant_processor = :disabled

initializer "application.hotcell", after: "active_storage.configs" do
  config.after_initialize do
    ActiveStorage.variant_transformer = HotCellActiveStorage::Transformer
    ActiveStorage.analyzers = [HotCellActiveStorage::ImageAnalyzer]
    ActiveStorage.previewers = [HotCellActiveStorage::PdfPreviewer]
  end
end
```

Client declarations, descriptor helpers, and Rails 8.1 adapter classes are in the Hot Cell initializer. Snapper-style
configuration uses only the remote image analyzer and no previewers; the example also demonstrates a remote PDF
previewer. Neither needs local video or audio analyzers. When upgrading to Rails 8.2, use upstream's client
adapters directly.

## Deploying the Hot Cell Remote service

The container example keeps the service in the application's `hotcell/` directory, but the service is not a
copy of the application. Its image uses the application's `Gemfile.lock` and takes only what the service needs:

| In the service | Not in the service |
| --- | --- |
| Ruby, and the tools that your operations run, such as libvips or poppler | Your application's code: `app/`, `config/`, `lib/` |
| The gems in the `hotcell` group: Hot Cell Remote, Hot Cell, Puma, and the gems that your operations use | Rails, and every gem outside the `hotcell` group |
| `hotcell/`: your operations and the service's `config.ru` | Your application's credentials, secrets, and database access |

The service reads your whole `Gemfile` and `Gemfile.lock`, which list every gem that your application uses, but
Bundler installs only the `hotcell` group (`BUNDLE_ONLY=hotcell`). Sharing one lockfile keeps the two sides on
the same versions of Hot Cell and Hot Cell Remote, and it means that one `bundle update` updates both.

Hot Cell Remote configures the service by convention, so `hotcell/` holds only what you've added. Copy it from the
example application's [`hotcell/`](examples/rails_app/hotcell):

```
hotcell/
  operations/            # your operations
  config.rb              # the cell's limits; optional
  config.ru              # the service
  Dockerfile             # the service's image; build it from the application's root
  Dockerfile.dockerignore
```

`config.ru` starts the service, and passes it the secret from the service's environment:

```ruby
require "hot_cell/remote/service"

run HotCell::Remote::Service.gateway(secret: ENV.fetch("HOTCELL_REMOTE_SECRET"))
```

### How the service runs

The service is one process tree. Puma runs the gateway, and `HotCell::Remote::Service.gateway` starts Hot Cell's
own `hotcell` command as a child process: a separate process, never inside Puma's, which forks a new worker for
each request. The cell's sockets and its scratch files are in private temporary directories. The gateway passes
each request to the cell unchanged, so it never parses an input or loads an operation. If the cell exits, the
gateway stops too, so that the platform restarts the whole service.

- Run Puma in single mode (`-w 0`), so that one gateway starts one cell.
- The service listens on `$PORT`, and answers `GET /up` for health checks.
- The cell's limits are in `hotcell/config.rb`, which calls
  [`HotCell.limits`](https://basecamp.github.io/hotcell/cell-settings/). The cell loads it when the file exists,
  and otherwise uses Hot Cell's defaults. Size `concurrency` and `OMP_NUM_THREADS` to the service's CPUs, and
  make the application's client `timeout` longer than `deadline` plus `queue_wait`.

Nothing in the image or in `config.ru` configures Hot Cell, so an update to the gem can change how the service
starts without a change to your application.

### Heroku buildpacks

Deploy the service as an ordinary Ruby/Rack app using Heroku's Ruby buildpack. Heroku installs the locked gems
and builds the slug; no Docker image or `heroku.yml` is required. Use a service-only source tree containing a
Gemfile and lockfile, a Ruby version file, and the `hotcell/` directory. Keep Rails application code and
credentials out of that tree.

The service bundle needs `hotcell-remote`, `puma`, `hotcell-server`, and the gems its operations use. For the
upstream image operations, include `activestorage-hotcell-server`. Keep the Hot Cell versions aligned with
the application's lockfile.

Add this `Procfile` to the service source tree:

```procfile
web: bundle exec puma -w 0 -p $PORT hotcell/config.ru
```

Install any native libraries and tools the operations need with a buildpack, before the Ruby buildpack.
For example, libvips and Poppler can be installed through an `Aptfile` and the
[APT buildpack](https://github.com/heroku/heroku-buildpack-apt); choose package names for the Heroku stack.
The HTTP gateway itself needs neither library.

```sh
heroku create my-app-hotcell --buildpack heroku/ruby
heroku buildpacks:add --index 1 https://github.com/heroku/heroku-buildpack-apt --app my-app-hotcell
heroku config:set HOTCELL_REMOTE_SECRET=… --app my-app-hotcell
# Push the service-only repository; Heroku builds it with the configured buildpacks.
git push https://git.heroku.com/my-app-hotcell.git main
```

Then configure the Rails app with `HOTCELL_REMOTE_URL=https://my-app-hotcell.herokuapp.com` and the same
`HOTCELL_REMOTE_SECRET`. See Heroku's [Rack deployment guide](https://devcenter.heroku.com/articles/rack).

### Container platforms

Build the image from the application's root and run it as one container:

```sh
docker build -f hotcell/Dockerfile -t hotcell-remote .
docker run -p 8080:8080 -e HOTCELL_REMOTE_SECRET=… hotcell-remote
```

On AWS ECS, run it as a service with one container. Give it no task role and no secrets except
`HOTCELL_REMOTE_SECRET`, and a security group that only your application can reach. Where the platform lets you,
also deny the service's outbound traffic, except what the platform itself needs, such as pulling the image and
sending logs.

### Deploying changes to operations

The application and the Hot Cell Remote service deploy separately, so for a few minutes one can be ahead of the
other. Hot Cell's failure codes cover that:

| Situation while out of sync | What the cell answers | Hot Cell's classification |
| --- | --- | --- |
| The application calls an operation that the service doesn't have yet | `unsupported` | transient |
| The application sends a payload key that the service's operation doesn't accept yet, or leaves out one that it requires | `failed`, because the operation raises `ArgumentError` | transient |
| The application calls an operation that the service has removed | `unsupported` | transient |

Each one is transient, so a job that retries `HotCell::TransientFailure` succeeds once both sides match. A call
that doesn't retry, such as a variant that's rendered during a web request, fails until then. So deploy the
service first when you add or extend an operation, and the application first when you remove one, and give new
payload keys defaults so that either order works.

### What the service gives up

Compared with Hot Cell's own deployment, the gateway and the cell share a container and a user, so:

- The cell has the same network as the gateway. Hot Cell's own deployment gives the cell no network at all. On
  Heroku, the service can reach the internet; elsewhere, restrict the service's outbound traffic.
- The cell runs as the same user as the gateway, so code that escapes a worker could read the files of other
  requests that the service is handling at that moment.
- Container settings such as a read-only root filesystem and dropped capabilities are up to the platform.

Parsing happens away from your application, in forked workers with memory and time limits. The service
still handles sensitive uploads and holds its bearer secret. A compromised worker shares the gateway's user
and network, so this does not isolate concurrent requests from each other or prevent access to that secret.
Keep application credentials and database access out of the service, and restrict its network access.
From most isolated to least:

1. Hot Cell's own deployment, where the platform supports it: the cell has its own user and no network.
2. Hot Cell Remote with the service's outbound traffic denied.
3. Hot Cell Remote on Heroku: no application credentials, but uploads and the bearer secret are present, and
   the service can reach the internet.
4. Hot Cell inside the application's own container: only crash and resource limits.

### The secret

The service is reachable over the network, so set `HOTCELL_REMOTE_SECRET` on both the application and the
service. `config.ru` reads it with `ENV.fetch`, so the service won't start without it. The gateway compares it
in constant time and refuses any request without it, except `GET /up`. Keep the service private where your
platform allows it, too: on Heroku, its URL is public.

## The HTTP API

The transport carries Hot Cell's own wire format over HTTP, so the application's client and the service's cell
agree on everything else, from payloads to failure codes.

```
POST /work          a request for an operation
POST /control       a describe or metrics request
GET  /up            a health check, which needs no secret
```

A request is `multipart/form-data`, with `Authorization: Bearer <secret>` when the service has one, and the
client's protocol version in `Hotcell-Remote-Protocol`. Its `request` part is Hot Cell's request line, and its
`input0`, `input1`, … parts are the inputs' bytes. A `401` means a missing or wrong secret.

Every relayed request answers `200`, and Hot Cell's response line says how it went. The body is:

1. A newline every 15 seconds while the cell works.
2. Hot Cell's response line.
3. A line with the outputs' sizes, separated by commas, which is empty when there are no outputs.
4. The outputs' bytes, one after another.

The client bounds response and size lines by Hot Cell's response limit, verifies that output counts match
the request, and rejects invalid sizes, truncated outputs, or trailing bytes. Malformed replies become
`unavailable` failures. The client timeout bounds the entire HTTP exchange, including connection, upload,
headers, and streamed output; keepalive bytes do not reset it. Each call uses a fresh connection with no
automatic retries. Retry transient failures at the job layer.

The newlines keep a router from timing out a slow operation. Heroku's router, for example, ends a request that
sends nothing for 30 seconds, and AWS load balancers end a connection that's idle for 60 seconds by default. The
client skips the newlines and writes each output straight into its file, so outputs never have to fit in memory.

## Development and test parity

In development and test, you don't have to run the service. When there's no URL and `Rails.env.local?` is true,
`HotCell::Remote.register` gives the cell a transport that runs each request inside the application's process, the
way a Hot Cell worker does, with the same results and the same failure codes. There's **no isolation**: no fork,
no limits, and no separate service. The Railtie never enables this in any other environment; applications can
explicitly opt in with `HotCell::Remote.inline = true` before registering a cell.

The application loads `hotcell/operations` when it registers the cell, so it needs Hot Cell's server and the
operations' gems in development and test too. Add those groups:

```ruby
group :development, :test, :hotcell do
  gem "hotcell-server"
  gem "image_processing"
  gem "ruby-vips"
end
```

Install the tools that your operations run, such as libvips or poppler, on development machines and in CI. Then
test operations through your clients with real fixture files:

```ruby
test "counts words" do
  Tempfile.create("words") do |file|
    file.write("one two three")
    file.flush
    result = File.open(file.path, "rb") { |input| HotCellClients::CountWords.perform_in_hotcell(input, []) }
    assert_equal 3, result[:words]
  end
end
```

Inline parity covers operation inputs, outputs, results, and failure classification. It does not emulate
supervisor scheduling, time or resource limits, or diagnostics. Control requests such as `describe` and
`metrics` return `unsupported`; run the service to test supervisor behavior.

## Contributing

```sh
bundle install
bundle exec rake test
bundle exec rubocop
```

The tests start the service with a real Hot Cell and the operations in `test/fixtures/operations`. They run on
macOS and Linux; use Linux to verify the production isolation behavior.

## License

MIT. See [LICENSE](LICENSE).
