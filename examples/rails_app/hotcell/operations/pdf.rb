# frozen_string_literal: true

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

  # Copies one page into its own PDF.
  class Page < HotCell::Operation
    operation "pdf.page"

    def perform(inputs, outputs, page:)
      page = Integer(page)
      output = outputs.first
      result = run_tool("pdfseparate", "-f", page.to_s, "-l", page.to_s, inputs.first.fd_path, output.path(extension: "%d.pdf"),
                        pass: [inputs.first.to_io])
      raise HotCell::UnreadableInput, result.err unless result.ok?

      output.adopt(output.path(extension: "#{page}.pdf"))
      {}
    end
  end

  # Draws one page as a PNG.
  class RenderPage < HotCell::Operation
    operation "pdf.render_page"

    def perform(inputs, outputs, page: 1, resolution: 72)
      output = outputs.first
      result = run_tool("pdftoppm", "-f", page.to_s, "-l", page.to_s, "-r", resolution.to_s, "-png", "-singlefile",
                        inputs.first.fd_path, output.path, pass: [inputs.first.to_io])
      raise HotCell::UnreadableInput, result.err unless result.ok?

      output.adopt(output.path(extension: "png"))
      {}
    end
  end
end
