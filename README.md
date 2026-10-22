# Hot Cell Remote

Run operations on untrusted files — PDFs, images, anything a C library has to parse — from a Rails application,
either in the application's process or in a separate, isolated service.

[Hot Cell](https://github.com/basecamp/hotcell) runs untrusted work in an unprivileged sibling container: forked
workers with memory and time limits, no network, and no credentials. It passes files as descriptors over a UNIX
socket, so the cell must share a host and a volume with the application.

Hot Cell Remote puts an HTTP API in front of a cell, so the cell can be its own service: in a different task, on a
different host, behind its own firewall rules. The same API also runs inside the application's process, so you can
write and ship operations before you deploy the service, and develop and test without running it at all.

```
                         HotcellRemote.perform("pdf.info", file)
                                          │
              ┌─────────── in process ────┴──── remote (HOTCELL_REMOTE_URL) ───┐
              ▼                                                                ▼
        Gateway (Rack)                                                   HTTP → Gateway (Rack)
              │                                                                │
       Inline executor                                                  HotCell executor
     (no isolation: runs                                          (UNIX socket, descriptors)
      the operation here)                                                      │
                                                                       Hot Cell → forked worker
                                                                               │
                                                                           operation
```

In process, operations run with **no isolation**. It's a stepping stone: the code paths, the API, and the errors
are the same, so moving to the remote service is a configuration change.

## Installation

Hot Cell Remote is a Rails engine. Put it, and the gems your operations need, in a `hotcell` Gemfile group that
the application shares with the service, and put the Hot Cell gems in that group only:

```ruby
# Gemfile
group :default, :hotcell do
  gem "hotcell-remote", github: "bensheldon/hotcell-remote"
  gem "puma"

  # What your operations use, for example:
  gem "image_processing"
  gem "ruby-vips"
end

group :hotcell do
  gem "hotcell-client"
  gem "hotcell-server"
end
```

Rails never loads the `hotcell` group, and the application's image doesn't need it:

```dockerfile
ENV BUNDLE_WITHOUT="development:test:hotcell"
```

The service's image installs only that group, with `BUNDLE_ONLY=hotcell`, from the same `Gemfile.lock`. It gets no
Rails and none of the application's other gems.

## Writing operations

Operations are application code. Put them in `hotcell/operations/`. The engine requires every file there when the
application boots, and the service's cell loads the same files. They're plain Ruby that the cell loads without
Rails, so don't put them in an autoloaded directory or use Rails in them.

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

Call them from anywhere in the application:

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
- `perform(input, output, **payload)` does the work. `input` and `output` are **paths**, so the operation runs the
  same in process and in a cell, where they're `/dev/fd/N` paths to the caller's descriptors. Return a Hash; it
  travels as JSON.
- The payload arrives as keyword arguments. Declare the ones you accept: the gateway rejects a missing or unknown
  keyword before it dispatches the operation. Payloads and results are JSON, so keys come back as strings and
  symbols as strings.
- `result_only` declares that the operation writes no file. Hot Cell treats an empty output as a failure, so an
  operation that writes nothing must declare it.
- `run(*command)` runs a tool with only `PATH`, `HOME`, and `LANG` in its environment and returns its standard
  output. In a cell, the tool receives the input's descriptor, so it can open the input's path. A tool that
  exits unsuccessfully raises `HotcellRemote::UnreadableInput`.
- `staged(output) { |dir| path }` is for tools that choose their own output file name: write into `dir`, return
  the file's path, and it's copied to `output`.
- Raise `HotcellRemote::UnreadableInput` when the input can't be decoded, for example from a library's own error.

Shell out with `run` rather than `system` or backticks: in a cell, a subprocess started any other way can't open
the input's path.

### Errors

`HotcellRemote.perform` raises:

- `HotcellRemote::PermanentError` when retrying won't help: the input is unreadable, the operation doesn't exist,
  or the payload is wrong.
- `HotcellRemote::TransientError` when retrying may: the service is unreachable or busy, or the cell restarted.

Let Active Job retry transient errors, and discard or record permanent ones.

### Testing

Operations run in process in development and test, so test them through `HotcellRemote.perform` with real
fixture files. Install the tools they use on development machines and CI.

## Configuration

| Setting | Default | Description |
| --- | --- | --- |
| `config.hotcell_remote.url` | `ENV["HOTCELL_REMOTE_URL"]` | The service's gateway. When it's set, calls go there. |
| `config.hotcell_remote.access_secret` | `ENV["HOTCELL_ACCESS_SECRET"]` | A shared secret the application sends as `Authorization: Bearer …`. |
| `config.hotcell_remote.allow_inline` | `true` in development and test | Whether to run operations in process when there's no URL. Otherwise a call raises `HotcellRemote::ConfigurationError`. |
| `config.hotcell_remote.operations_path` | `hotcell/operations` | The directory of operation files. |
| `config.hotcell_remote.active_storage` | none | Classes to install in Active Storage. See below. |

To run in process in production before the service exists, opt in:

```ruby
# config/environments/production.rb
config.hotcell_remote.allow_inline = true
```

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

[`examples/hotcell`](examples/hotcell) has everything below. Copy it to `hotcell/` in your application.

```
hotcell/
  operations/            # your operations, loaded by the application and the cell
  config.rb              # the cell's limits; requires hotcell_remote/cell
  config.ru              # the gateway
  Dockerfile             # one image for both containers; build it from the application's root
  Dockerfile.dockerignore
```

### The image

```sh
docker build -f hotcell/Dockerfile -t hotcell-remote .
```

The image installs the tools your operations use and the `hotcell` group from your `Gemfile.lock`. Build it from
the application's root so it can read the lockfile.

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
- The cell sweeps its `TMPDIR` when it boots. Never share the cell's `TMPDIR` with anything else, and keep the
  socket directory outside it.
- Set `concurrency`, `memory`, and `deadline` in `config.rb`, and match `OMP_NUM_THREADS` to the cell's CPUs.

Then point the application at the gateway:

```sh
HOTCELL_REMOTE_URL=http://hotcell-remote.internal:8080
HOTCELL_ACCESS_SECRET=…   # the same value on the application and the gateway
```

### Network isolation

The point of the service is that code execution in a worker gets nothing worth having. Hot Cell's own deployment
removes the cell's network. Where you can, do that too: with Kamal or Docker, give the `cell` container
`network: none` and only the `gateway` a network.

On AWS ECS Fargate, every container in a task shares one network namespace, so the cell can't have its own.
Isolate the whole task instead:

- A security group that allows ingress on `8080` from the application only, and **no egress** except the VPC
  endpoints Fargate needs: ECR (`ecr.api`, `ecr.dkr`), S3 (for image layers), and CloudWatch Logs.
- **No task role**, so the credentials endpoint has nothing to give. Its execution role needs no secrets.
- A private address, through Service Connect or Cloud Map, rather than a public load balancer.
- Fargate doesn't let you set `kernel.yama.ptrace_scope`, so the cell logs `cell.ptrace_scope_unknown` and boots
  anyway. See Hot Cell's [worker isolation](https://basecamp.github.io/hotcell/design/worker-isolation/) for
  what that leaves open.

### The access secret

When the gateway is reachable by more than the application, set `HOTCELL_ACCESS_SECRET` on both. The gateway
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

## Development

```sh
bundle install
bundle exec rake test
bundle exec rubocop
```

The tests boot a real Hot Cell with the operations in `test/fixtures/operations`, so they need Linux.

## License

MIT. See [LICENSE](LICENSE).
