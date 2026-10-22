# Hot Cell Remote

Run [Hot Cell](https://github.com/basecamp/hotcell) as a network service — not a sidecar — to run operations on
untrusted files.

[Hot Cell](https://github.com/basecamp/hotcell) runs untrusted work in an unprivileged sibling container on the
same host as the application, which passes it file descriptors over a UNIX socket on a shared volume. Hot Cell
Remote instead runs the cell inside a small service of its own, with an HTTP gateway in front of it. The
application sends each file to the service and gets the result back.

The goal is operational simplicity: the service deploys as one unit, such as a Heroku dyno or a single
container, with no sidecars, shared volumes, or special container settings. It still isolates the parsing of
untrusted files from your application: the service has none of your application's code, secrets, credentials,
or database access. It gives up some of the protections of Hot Cell's own deployment, which are described under
[What the service gives up](#what-the-service-gives-up).

```
  Rails application                            hotcell-remote service (one dyno or container)
  ─────────────────                            ───────────────────────────────────────────────────
  HotcellRemote.perform("pdf.info", file)  ──HTTP──▶  Gateway (Puma) ──UNIX socket──▶ Hot Cell
                                                                                    └─ forked worker
                                                                                        └─ operation
```

[`examples/rails_app`](examples/rails_app) is a minimal Rails application that has every piece below in its
place: the Gemfile, the operations, the service's `hotcell/` directory, both Dockerfiles, an Active Storage
setup, a job, and a test.

## Installation

Hot Cell Remote is a Rails engine. The application and the service share one Gemfile and one `Gemfile.lock`, and
a `hotcell` group holds what only the service needs: the Hot Cell gems, and the gems that your operations use.

```ruby
# Gemfile
group :default, :hotcell do
  gem "hotcell-remote", github: "bensheldon/hotcell-remote"
  gem "puma"
end

group :hotcell do
  gem "hotcell-client"
  gem "hotcell-server"

  # Gems that your operations use, for example:
  gem "image_processing"
  gem "ruby-vips"
end
```

Rails never loads the `hotcell` group, and the application's image leaves it out, along with the tools that your
operations run:

```dockerfile
ENV BUNDLE_WITHOUT="development:test:hotcell"
```

The service's image installs only the `hotcell` group, with `BUNDLE_ONLY=hotcell`. It gets no Rails and none of
the application's other gems.

## Writing operations

Operations are application code, but they run only in the service. Put them in `hotcell/operations/`, where the
service's gateway and cell load them. They're plain Ruby that the service loads without Rails, so don't put them
in an autoloaded directory or use Rails in them.

```ruby
# hotcell/operations/pdf.rb
module PdfOperations
  class Info < HotcellRemote::Operation
    operation "pdf.info"
    result_only

    def perform(input, _output)
      fields = run("pdfinfo", input).lines.to_h { |line| line.split(":", 2).map(&:strip) }

      { pages: Integer(fields.fetch("Pages")) }
    end
  end

  # Copies one page into its own PDF.
  class Page < HotcellRemote::Operation
    operation "pdf.page"

    def perform(input, output, page:)
      staged(output) do |dir|
        run("pdfseparate", "-f", Integer(page), "-l", Integer(page), input, File.join(dir, "page-%d.pdf"))
        File.join(dir, "page-#{Integer(page)}.pdf")
      end

      { content_type: "application/pdf" }
    end
  end
end
```

The application calls them by name, from anywhere:

```ruby
File.open(path, "rb") do |file|
  HotcellRemote.perform("pdf.info", file).result        # => { "pages" => 3 }
end

response = blob.open { |file| HotcellRemote.perform("pdf.page", file, page: 2) }
response.output                                          # => the page's PDF bytes
response.result                                          # => { "content_type" => "application/pdf" }
```

### The operation API

- `operation "name"` names the operation and registers it. Callers use the name.
- `perform(input, output, **payload)` does the work. `input` and `output` are **paths**: in the cell, they're `/dev/fd/N`
  paths to the descriptors that the gateway passed. Return a Hash; it
  travels as JSON.
- The payload arrives as keyword arguments. Declare the ones that the operation accepts, because the gateway rejects a
  missing or unknown keyword before it dispatches the operation. Payloads and results are JSON, so keys come back as strings and
  symbols as strings.
- `result_only` declares that the operation writes no file. Hot Cell treats an empty output as a failure, so an
  operation that writes nothing must declare it.
- `run(*command)` runs a tool with only `PATH`, `HOME`, and `LANG` in its environment and returns its standard
  output. In a cell, the tool receives the input's descriptor, so it can open the input's path. A tool that
  exits unsuccessfully raises `HotcellRemote::UnreadableInput`.
- `staged(output) { |dir| path }` is for tools that choose their own output file name: write into `dir`, return
  the file's path, and it's copied to `output`.
- Raise `HotcellRemote::UnreadableInput` when the input can't be decoded, for example from a library's own error.

Shell out with `run` rather than `system` or backticks. In a cell, a subprocess that starts any other way can't open
the input's path.

### Errors

`HotcellRemote.perform` raises:

- `HotcellRemote::PermanentError` when retrying won't help: the input is unreadable, the operation doesn't exist,
  or the payload is wrong.
- `HotcellRemote::TransientError` when retrying may: the service is unreachable or busy, or the cell restarted.

Let Active Job retry transient errors, and discard or record permanent ones.

## Configuration

| Setting | Default | Description |
| --- | --- | --- |
| `config.hotcell_remote.url` | `ENV["HOTCELL_REMOTE_URL"]` | The service's gateway. |
| `config.hotcell_remote.access_secret` | `ENV["HOTCELL_REMOTE_SECRET"]` | A shared secret that the application sends as `Authorization: Bearer …`. |
| `config.hotcell_remote.operations_path` | `hotcell/operations` | The directory of operation files, for [development and test parity](#development-and-test-parity). |
| `config.hotcell_remote.active_storage` | none | Classes to install in Active Storage. See below. |

Without a URL, a call outside development and test raises `HotcellRemote::ConfigurationError`.

## Active Storage

Active Storage decodes files on its own: variants, image analysis, and previews. To route them through your
operations, write a transformer, an analyzer, and a previewer that call them, and name them:

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
analyzer, and a PDF previewer for its [operations](examples/rails_app/hotcell/operations). It also sets
`config.active_storage.variant_processor = :disabled`, so that Rails doesn't look for libvips in the
application.

## Deploying the service

The service lives in your application's repository, in a `hotcell/` directory, but it isn't a copy of your
application. It shares your `Gemfile.lock`, and takes only what the service needs:

| In the service | Not in the service |
| --- | --- |
| Ruby, and the tools that your operations run, such as libvips or poppler | Your application's code: `app/`, `config/`, `lib/` |
| The gems in the `hotcell` group: Hot Cell Remote, the Hot Cell gems, Puma, and the gems that your operations use | Rails, and every gem outside the `hotcell` group |
| `hotcell/`: your operations and the service's `config.ru` | Your application's credentials, secrets, and database access |

The service installs your whole `Gemfile` and `Gemfile.lock`, which list every gem that your application uses,
but Bundler installs only the `hotcell` group (`BUNDLE_ONLY=hotcell`). Sharing one lockfile keeps the service's
copy of Hot Cell Remote at the same version as the application's, so the two sides of the HTTP API always agree,
and it means that one `bundle update` updates both.

Hot Cell Remote configures the service by convention, so `hotcell/` holds only what's yours. Copy it from the
example application's [`hotcell/`](examples/rails_app/hotcell):

```
hotcell/
  operations/            # your operations
  config.ru              # the service
  Dockerfile             # the service's image; build it from the application's root
  Dockerfile.dockerignore
```

`config.ru` is two lines:

```ruby
require "hotcell_remote/service"

run HotcellRemote::Service.gateway
```

### How the service runs

The service is one process tree. Puma runs the gateway, and `HotcellRemote::Service.gateway` starts the Hot Cell
as a child process: a separate process, never inside Puma's, which forks a new worker for each request. The cell's
sockets and its scratch files are in private temporary directories. If the cell exits, the gateway stops too, so
that the platform restarts the whole service.

- Run Puma in single mode (`-w 0`), so that one gateway starts one cell.
- The service listens on `$PORT`, and answers `GET /up` for health checks.
- The cell uses Hot Cell's default limits. To change `concurrency`, `memory`, or `deadline`, add a
  `hotcell/config.rb` that calls `HotCell.limits`, which the cell loads when the file exists. Match
  `OMP_NUM_THREADS` to the service's CPUs.

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

### What the service gives up

Compared with Hot Cell's own deployment, the gateway and the cell share a container and a user, so:

- The cell has the same network as the gateway. Hot Cell's own deployment gives the cell no network at all. On
  Heroku, the service can reach the internet; elsewhere, restrict the service's outbound traffic.
- The cell runs as the same user as the gateway, so code that escapes a worker could read the files of other
  requests that the service is handling at that moment.
- Container settings such as a read-only root filesystem and dropped capabilities are up to the platform.

What it keeps is what matters most: the parsing of untrusted files happens away from your application, in a
service that has nothing worth stealing, in forked workers with memory and time limits.

### The access secret

The service is reachable over the network, so set `HOTCELL_REMOTE_SECRET` on both the application and the
service. The gateway compares it in constant time and answers `401` to any request without it, except
`GET /up`. Keep the service private where your platform allows it, too: on Heroku, its URL is public.

## The HTTP API

```
POST /ops/<operation>
Authorization: Bearer <secret>                 (when the gateway has one)
Hotcell-Remote-Payload: {"page": 2}            (JSON object; optional)

<the input file's bytes>
```

| Status | Body |
| --- | --- |
| `200`, operation writes a file | The file's bytes. The result is JSON in the `Hotcell-Remote-Result` header. |
| `200`, `result_only` operation | The result as JSON. |
| `400` | A bad payload. `{"error": "…"}` |
| `401` | A missing or wrong access secret. |
| `404` | An unknown operation. |
| `422` | The input couldn't be processed. A permanent failure. |
| `503` | The cell is unavailable or failed transiently. Retry. |

## Development and test parity

In development and test, you don't have to run the service. When there's no URL and `Rails.env.local?` is true,
`HotcellRemote.perform` runs the same gateway inside the application's process, and the gateway runs the
operation there. The API, the payload checks, and the errors are the same as the service's, but there's **no
isolation**, so the engine never does this in any other environment.

The application loads `hotcell/operations` the first time that an operation runs in process, so it needs the
operations' gems in development and test too. Add those groups to the operation gems:

```ruby
group :development, :test, :hotcell do
  gem "image_processing"
  gem "ruby-vips"
end
```

Install the tools that your operations run, such as libvips or poppler, on development machines and in CI. Then
test operations through `HotcellRemote.perform` with real fixture files:

```ruby
test "reads the page count" do
  response = file_fixture("two-pages.pdf").open { |file| HotcellRemote.perform("pdf.info", file) }

  assert_equal 2, response.result["pages"]
end
```

## Contributing

```sh
bundle install
bundle exec rake test
bundle exec rubocop
```

The tests boot a real Hot Cell with the operations in `test/fixtures/operations`, so they need Linux.

## License

MIT. See [LICENSE](LICENSE).
