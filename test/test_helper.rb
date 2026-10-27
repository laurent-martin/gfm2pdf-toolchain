# frozen_string_literal: true

require 'minitest/autorun'
require 'open3'
require 'pathname'
require 'tmpdir'
require_relative '../lib/pandoc'

Gfm2Pdf.log.level = ENV.fetch('GFM2PDF_LOG_LEVEL', 'warn')
# Tests give the theme explicitly, not the one of the environment
ENV.delete('GFM2PDF_THEME')

module TestHelper
  ROOT = Gfm2Pdf::ROOT
  FIXTURES = ROOT / 'test/fixtures'

  # Convert Markdown with the pandoc defaults of the toolchain
  # @param markdown [String] Markdown text
  # @param output   [String] Folder of the output specific defaults: `latex`, `typst` or `html`
  # @param to       [String] Pandoc output format
  # @return [String] Pandoc output
  def pandoc(markdown, output, to)
    out, err, status = Open3.capture3(
      'pandoc', "--defaults=#{ROOT / 'common/defaults.yaml'}", "--defaults=#{ROOT / output / 'defaults.yaml'}", "--to=#{to}",
      stdin_data: markdown
    )
    assert(status.success?, err)
    out
  end

  # Skip the test if the command is not in the PATH
  # @param name [String] Command name
  def require_command(name)
    found = ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).any? { |dir| File.executable?(File.join(dir, name)) }
    skip("#{name} not found") unless found
  end

  # Text of a PDF file
  # @param pdf [Pathname] PDF file
  # @return [String]
  def pdf_text(pdf)
    require_command('pdftotext')
    out, status = Open3.capture2('pdftotext', pdf.to_s, '-')
    assert(status.success?)
    out
  end

  # Number of pages of a PDF file
  # @param pdf [Pathname] PDF file
  # @return [Integer]
  def pdf_pages(pdf)
    require_command('pdfinfo')
    out, status = Open3.capture2('pdfinfo', pdf.to_s)
    assert(status.success?)
    out[/^Pages:\s+(\d+)/, 1].to_i
  end

  # Pages of a PDF file with a raster image, e.g. the background of the cover, or an emoji
  # @param pdf [Pathname] PDF file
  # @return [Array<Integer>] Page numbers
  def pdf_image_pages(pdf)
    require_command('pdfimages')
    out, status = Open3.capture2('pdfimages', '-list', pdf.to_s)
    assert(status.success?)
    # After the 2 heading lines, the first column is the page number
    out.lines.drop(2).map { |line| line.split.first.to_i }.uniq
  end

  # Fonts of a PDF file
  # @param pdf [Pathname] PDF file
  # @return [String] Font list, one per line, with its PDF name, e.g. `LMSans10-Regular`
  def pdf_fonts(pdf)
    require_command('pdffonts')
    out, status = Open3.capture2('pdffonts', pdf.to_s)
    assert(status.success?)
    out
  end

  # Call the block with a temporary copy of the fixtures folder
  # @yieldparam dir [Pathname]
  def with_fixtures
    Dir.mktmpdir('test') do |dir|
      FileUtils.cp_r("#{FIXTURES}/.", dir)
      yield(Pathname.new(dir))
    end
  end
end
