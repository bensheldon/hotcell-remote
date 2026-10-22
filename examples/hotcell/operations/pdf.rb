# frozen_string_literal: true

module PdfOperations
  class Info < HotcellRemote::Operation
    operation "pdf.info"
    result_only

    def perform(input, _output)
      fields = run("pdfinfo", input).lines.to_h { |line| line.split(":", 2).map(&:strip) }
      width, height = fields["Page size"].to_s.scan(/[\d.]+/).first(2).map(&:to_f)

      { pages: Integer(fields.fetch("Pages")), encrypted: fields["Encrypted"].to_s.start_with?("yes"), page_size: [width, height] }
    end
  end

  class Text < HotcellRemote::Operation
    operation "pdf.text"
    result_only

    def perform(input, _output, first_page: 1, last_page: nil)
      command = ["pdftotext", "-layout", "-enc", "UTF-8", "-f", Integer(first_page)]
      command += ["-l", Integer(last_page)] if last_page
      pages = run(*command, input, "-").split("\f")
      pages.pop if pages.last&.strip&.empty?

      { pages: }
    end
  end

  # Copies one page into its own PDF.
  class Page < HotcellRemote::Operation
    operation "pdf.page"

    def perform(input, output, page:)
      page = Integer(page)
      staged(output) do |dir|
        run("pdfseparate", "-f", page, "-l", page, input, File.join(dir, "page-%d.pdf"))
        File.join(dir, "page-#{page}.pdf")
      end

      { content_type: "application/pdf" }
    end
  end

  class RenderPage < HotcellRemote::Operation
    operation "pdf.render_page"

    FORMATS = { "jpeg" => "jpg", "png" => "png" }.freeze

    def perform(input, output, page: 1, resolution: 150, format: "jpeg")
      extension = FORMATS.fetch(format) { raise ArgumentError, "format must be one of #{FORMATS.keys.join(', ')}" }
      staged(output) do |dir|
        run("pdftoppm", "-f", Integer(page), "-l", Integer(page), "-r", Integer(resolution), "-#{format}", "-singlefile", input, File.join(dir, "page"))
        File.join(dir, "page.#{extension}")
      end

      { content_type: "image/#{format}" }
    end
  end
end
