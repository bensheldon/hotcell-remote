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
place: the Gemfile, the operations and clients, the service's `hotcell/` directory, both Dockerfiles, a Heroku
setup, Active Storage, a job, and a test.

## Installation

Hot Cell Remote is a Rails engine. The application and the service share one Gemfile and one `Gemfile.lock`, and
a `hotcell` group holds what only the service needs: Hot Cell's server, and the gems that your operations use.

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

Operations are application code that runs only in the service. Put them in `hotcell/operations/`, where the
service's cell loads them:

```ruby
# hotcell/operations/pdf.rb
module PdfOperations
  class Info < HotCell::Operation
    operation "pdf.info"

    def perform(inputs, _outputs)
      result = run_tool("pdfinfo", inputs.first.fd_path, pass: [inputs.first.to_io])
      raise HotCell::UnreadableInput, result.err unless result.ok?

      fields = result.out.lines.to_h { |line| line.split(":", 2).map(&:strip) }
      { pages: Integer(fields.fetch("Pages")) }
    end
  end
end
```

The application calls them with clients that name the registered cell:

```ruby
# app/clients/read_pdf_info.rb
class ReadPdfInfo < HotCell::Client
  hotcell "media"
  operation "pdf.info"
end

File.open(path, "rb") { |input| ReadPdfInfo.perform_in_hotcell(input, []) }   # => { pages: 3 }
```

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
| `config.hotcell_remote.active_storage` | none | Classes to install in Active Storage. See below. |

Without a URL, outside development and test, `HotCell::Remote.register` raises `HotCell::Remote::ConfigurationError`,
so the application doesn't boot.

## Active Storage

Active Storage decodes files on its own: variants, image analysis, and previews. To send them to the service,
write a transformer, an analyzer, and a previewer that call your clients, and name them:

```ruby
# config/initializers/active_storage.rb
Rails.application.config.hotcell_remote.active_storage.tap do |active_storage|
  active_storage.variant_transformer = "HotcellActiveStorage::Transformer"
  active_storage.analyzers = %w[HotcellActiveStorage::ImageAnalyzer ActiveStorage::Analyzer::VideoAnalyzer]
  active_storage.previewers = %w[HotcellActiveStorage::PdfPreviewer ActiveStorage::Previewer::VideoPreviewer]
end
```

The engine installs them after Active Storage applies `config.active_storage`, which would otherwise replace
them. The example application's
[`lib/hotcell_active_storage`](examples/rails_app/lib/hotcell_active_storage) has a transformer, an image
analyzer, and a PDF previewer. It also sets `config.active_storage.variant_processor = :disabled`, so that Rails
doesn't look for libvips in the application.

## Deploying the Hot Cell Remote service

The Hot Cell Remote service lives in your application's repository, in a `hotcell/` directory, but it isn't a
copy of your application. It shares your `Gemfile.lock`, and takes only what the service needs:

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

### Heroku

Create a second Heroku app for the service, from the same repository, on the container stack:

```sh
heroku create my-app-hotcell --stack container
heroku config:set HOTCELL_REMOTE_SECRET=… --app my-app-hotcell
git push https://git.heroku.com/my-app-hotcell.git main
```

The example application's [`heroku.yml`](examples/rails_app/heroku.yml) builds `hotcell/Dockerfile` for the
`web` process. Your application's own Heroku app keeps using its buildpacks, which ignore `heroku.yml`. Then
point the application at the service:

```sh
heroku config:set HOTCELL_REMOTE_URL=https://my-app-hotcell.herokuapp.com HOTCELL_REMOTE_SECRET=… --app my-app
```

### Other platforms

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

What it keeps is what matters most: the parsing of untrusted files happens away from your application, in a
service that has nothing worth stealing, in forked workers with memory and time limits. From most isolated to
least:

1. Hot Cell's own deployment, where the platform supports it: the cell has its own user and no network.
2. Hot Cell Remote with the service's outbound traffic denied.
3. Hot Cell Remote on Heroku: no secrets, but the service can reach the internet.
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

The newlines keep a router from timing out a slow operation. Heroku's router, for example, ends a request that
sends nothing for 30 seconds, and AWS load balancers end a connection that's idle for 60 seconds by default. The
client skips the newlines and writes each output straight into its file, so outputs never have to fit in memory.

## Development and test parity

In development and test, you don't have to run the service. When there's no URL and `Rails.env.local?` is true,
`HotCell::Remote.register` gives the cell a transport that runs each request inside the application's process, the
way a Hot Cell worker does, with the same results and the same failure codes. There's **no isolation**: no fork,
no limits, and no separate service. The engine never does this in any other environment.

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
test "reads the page count" do
  result = file_fixture("two-pages.pdf").open("rb") { |input| ReadPdfInfo.perform_in_hotcell(input, []) }

  assert_equal 2, result[:pages]
end
```

## Contributing

```sh
bundle install
bundle exec rake test
bundle exec rubocop
```

The tests start the service with a real Hot Cell and the operations in `test/fixtures/operations`, so they need
Linux.

## License

MIT. See [LICENSE](LICENSE).
