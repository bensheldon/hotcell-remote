# Hot Cell Remote

Run [Hot Cell](https://github.com/basecamp/hotcell) as a network service — not a sidecar — to run operations on
untrusted files.

[Hot Cell](https://github.com/basecamp/hotcell) runs untrusted work in an unprivileged sibling container: forked
workers with memory and time limits, no network, and no credentials. It passes files as descriptors over a UNIX
socket, so the cell must share a host and a volume with the application.

Hot Cell Remote puts an HTTP API in front of a cell, so the cell can be its own service: in a different task, on a
different host, behind its own firewall rules, and without any of the secrets that the application holds.

```
  Rails application                              hotcell-remote service
  ─────────────────                              ──────────────────────────────────────────────
  HotcellRemote.perform("pdf.info", file)  ──HTTP──▶  Gateway ──UNIX socket──▶ Hot Cell
                                                      (Rack)    (descriptors)   └─ forked worker
                                                                                     └─ operation
```

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
them. [`examples/lib/hotcell_active_storage`](examples/lib/hotcell_active_storage) has a transformer, an image
analyzer, and a PDF previewer for the operations in
[`examples/hotcell/operations`](examples/hotcell/operations).

## Deploying the service

The service lives in your application's repository, in a `hotcell/` directory, but it isn't a copy of your
application. Its image is built from the repository so that it can share your `Gemfile.lock`, and then it takes
only what the service needs:

| In the service's image | Not in the service's image |
| --- | --- |
| Ruby, and the tools that your operations run, such as libvips or poppler | Your application's code: `app/`, `config/`, `lib/` |
| The gems in the `hotcell` group: Hot Cell Remote, the Hot Cell gems, Puma, and the gems that your operations use | Rails, and every gem outside the `hotcell` group |
| `hotcell/`: your operations, the cell's `config.rb`, and the gateway's `config.ru` | Your application's credentials, secrets, and database access |

The Dockerfile copies the whole `Gemfile` and `Gemfile.lock`, which list every gem that your application uses,
but Bundler installs only the `hotcell` group (`BUNDLE_ONLY=hotcell`). Sharing one lockfile keeps the service's
copy of Hot Cell Remote at the same version as the application's, so the two sides of the HTTP API always agree,
and it means that one `bundle update` updates both. `Dockerfile.dockerignore` limits the build to `.ruby-version`,
the Gemfile and lockfile, and `hotcell/`, so nothing else from the repository reaches the image.

The service runs as two processes from that image, the gateway and the cell, which are described under
[Two containers](#two-containers). Neither one loads Rails.

[`examples/hotcell`](examples/hotcell) has everything below. Copy it to `hotcell/` in your application.

```
hotcell/
  operations/            # your operations, which the service loads
  config.rb              # the cell's limits; requires hotcell_remote/cell
  config.ru              # the gateway
  Dockerfile             # one image for both containers; build it from the application's root
  Dockerfile.dockerignore
```

### The image

```sh
docker build -f hotcell/Dockerfile -t hotcell-remote .
```

Run the build from the application's root, because the image needs the root's `Gemfile.lock`.

### Two containers

Run the image as two containers that share a volume at `/run/hotcell`:

| Container | Command | User | Network |
| --- | --- | --- | --- |
| `cell` | the default, `bundle exec hotcell` | `10001:10001` | none, if your platform allows it |
| `gateway` | `bundle exec puma --port 8080 config.ru` | `10002:10001` | reachable by the application only |

- The gateway runs in the cell's group (`10001`), so it can reach the cell's sockets and share each request's
  files with the cell, without sharing the cell's user.
- Health checks: the image's `HEALTHCHECK` probes the cell, and the gateway answers `GET /up`.
- Give both containers a read-only root filesystem, drop every Linux capability, and set no secrets. Hot Cell's
  [container settings](https://basecamp.github.io/hotcell/container/) describe the rest.
- When the cell boots, it sweeps its temporary directory and removes everything that its user owns there. If
  `TMPDIR` isn't set, `hotcell_remote/cell` gives the cell a new directory of its own, so that a cell which runs
  outside its own container can't sweep a shared `/tmp`. If you do set `TMPDIR`, choose a directory that only the
  cell uses, and keep the socket directory outside it.
- Set `concurrency`, `memory`, and `deadline` in `config.rb`, and match `OMP_NUM_THREADS` to the cell's CPUs.

Then point the application at the gateway:

```sh
HOTCELL_REMOTE_URL=http://hotcell-remote.internal:8080
HOTCELL_REMOTE_SECRET=…   # the same value on the application and the gateway
```

### Network isolation

The point of the service is that code execution in a worker gets nothing worth having. Hot Cell's own deployment
removes the cell's network. Where you can, do that too: with Kamal or Docker, give the `cell` container
`network: none` and only the `gateway` a network.

On AWS ECS Fargate, every container in a task shares one network namespace, so the cell can't have its own.
Isolate the whole task instead:

- A security group that allows ingress on `8080` from the application only, and **no egress** except to the VPC
  endpoints that Fargate needs: ECR (`ecr.api`, `ecr.dkr`), S3 (for image layers), and CloudWatch Logs.
- **No task role**, so the credentials endpoint has nothing to give. Its execution role needs no secrets.
- A private address, through Service Connect or Cloud Map, rather than a public load balancer.
- Fargate doesn't let you set `kernel.yama.ptrace_scope`, so the cell logs `cell.ptrace_scope_unknown` and boots
  anyway. See Hot Cell's [worker isolation](https://basecamp.github.io/hotcell/design/worker-isolation/) for
  what that leaves open.

### The access secret

When the gateway is reachable by more than the application, set `HOTCELL_REMOTE_SECRET` on both. The gateway
compares it in constant time and answers `401` to any request without it, except `GET /up`. It's light
authorization for an endpoint that would otherwise run work for anyone who can reach it, not a replacement for
keeping the gateway private.

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
