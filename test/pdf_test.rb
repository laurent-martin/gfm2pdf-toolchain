# frozen_string_literal: true

require_relative 'test_helper'

# End to end: Markdown to PDF and HTML
class PdfTest < Minitest::Test
  include TestHelper

  # Texts expected in the generated documents
  EXPECTED = [
    'Sample document',
    'Sample subtitle',
    'Hello from the sample',
    'Note',
    'download_partial_suffix',
    'ascli config preset overview',
    # continuation of a long code line
    '↪',
    'End of document'
  ].freeze
  # Manual caption of the image: once, without number added by the PDF engine
  CAPTION = 'Figure 1: Logo of the sample'

  # Generate the PDF of the sample with the engine, and check its text
  def check_pdf(engine)
    with_fixtures do |dir|
      pdf = dir / 'out/sample.pdf'
      # mode check: the sample has no warnings
      Gfm2Pdf.markdown_to_pdf(md: dir / 'sample.md', pdf: pdf, engine: engine, mode: 'check')
      text = pdf_text(pdf)
      EXPECTED.each { |expected| assert_includes(text, expected) }
      assert_equal(1, text.scan(CAPTION).length, text)
      refute_match(/Figure 1(\.1)?:\s*Figure/, text)
      assert_empty(dir.glob('.tmp.*'), 'temporary files removed')
      yield(dir, pdf) if block_given?
    end
  end

  def test_typst
    require_command('typst')
    check_pdf('typst')
  end

  # Mode check: a warning of Typst (it has no option for it) is an error, and there is no PDF
  def test_typst_check_warning
    require_command('typst')
    with_fixtures do |dir|
      md = dir / 'font.md'
      md.write("# Font\n\n## Unknown\n\n```{=typst}\n#text(font: \"NoSuchFont\")[x]\n```\n")
      pdf = dir / 'out/font.pdf'
      capture_subprocess_io { Gfm2Pdf.markdown_to_pdf(md: md, pdf: pdf, engine: 'typst', mode: 'build') }
      assert_path_exists(pdf)
      _out, err = capture_subprocess_io do
        error = assert_raises(RuntimeError) { Gfm2Pdf.markdown_to_pdf(md: md, pdf: pdf, engine: 'typst', mode: 'check') }
        assert_equal('typst: failing because there were warnings', error.message)
      end
      assert_includes(err, 'unknown font family: nosuchfont')
      refute_path_exists(pdf)
    end
  end

  def test_typst_is_reproducible
    require_command('typst')
    check_pdf('typst') do |dir, pdf|
      first = pdf.binread
      Gfm2Pdf.markdown_to_pdf(md: dir / 'sample.md', pdf: pdf, engine: 'typst')
      assert(first == pdf.binread, 'same PDF for the same Markdown file')
    end
  end

  # The PDF next to an SVG image is used instead, with its text
  def test_typst_pdf_image
    require_command('typst')
    with_fixtures do |dir|
      (dir / 'image.typ').write("#set page(width: auto, height: auto, margin: 1pt)\nText of the PDF image\n")
      out, status = Open3.capture2e('typst', 'compile', 'image.typ', chdir: dir.to_s)
      assert(status.success?, out)
      pdf = dir / 'out/sample.pdf'
      Gfm2Pdf.markdown_to_pdf(md: dir / 'sample.md', pdf: pdf, engine: 'typst')
      assert_includes(pdf_text(pdf), 'Text of the PDF image')
    end
  end

  def test_latex
    require_command('lualatex')
    check_pdf('latex')
  end

  # Symbol missing in the main font and in the emoji font, in text and in code: shown with a fallback font, not dropped.
  # LaTeX: the fallback fonts of TeX Live set by lib/pandoc.rb, Typst: its own fallback to any font that has it.
  def check_symbol_fallback(engine)
    with_fixtures do |dir|
      md = dir / 'symbol.md'
      md.write("# Symbols\n\n## Mark\n\nNot saved: ●.\n\n```\ncode: ●\n```\n")
      pdf = dir / 'out/symbol.pdf'
      Gfm2Pdf.markdown_to_pdf(md: md, pdf: pdf, engine: engine)
      text = pdf_text(pdf)
      assert_includes(text, 'Not saved: ●.')
      assert_includes(text, 'code: ●')
    end
  end

  def test_typst_symbol_fallback
    require_command('typst')
    check_symbol_fallback('typst')
  end

  def test_latex_symbol_fallback
    require_command('lualatex')
    check_symbol_fallback('latex')
  end

  # Background of the cover and last pages, and fonts: from the theme only
  # @param font [String] Main font of the theme, as named in the PDF
  def check_theme(engine, font)
    with_fixtures do |dir|
      pdf = dir / 'out/sample.pdf'
      Gfm2Pdf.markdown_to_pdf(md: dir / 'sample.md', pdf: pdf, engine: engine)
      assert_empty(pdf_image_pages(pdf) & [1, pdf_pages(pdf)], 'no background without theme')
      refute_includes(pdf_fonts(pdf), font)
      Gfm2Pdf.markdown_to_pdf(md: dir / 'sample.md', pdf: pdf, engine: engine, theme: dir / 'theme')
      cover_pages = [1, pdf_pages(pdf)]
      assert_equal(cover_pages, pdf_image_pages(pdf) & cover_pages, 'background of the cover and last pages')
      assert_includes(pdf_fonts(pdf), font)
      assert_includes(pdf_text(pdf), 'End of document')
    end
  end

  def test_typst_theme
    require_command('typst')
    check_theme('typst', 'LibertinusSerif')
  end

  def test_latex_theme
    require_command('lualatex')
    check_theme('latex', 'LMSans')
  end

  # Theme with another background on the last page, and its own text on the cover, 12 mm from the edges of the page
  def check_theme_cover(engine)
    with_fixtures do |dir|
      pdf = dir / 'out/sample.pdf'
      Gfm2Pdf.markdown_to_pdf(md: dir / 'sample.md', pdf: pdf, engine: engine, theme: dir / 'theme_cover')
      assert_equal([200, 20], pdf_image_size(pdf, 1), 'background of the cover')
      assert_equal([100, 10], pdf_image_size(pdf, pdf_pages(pdf)), 'background of the last page')
      left, top = pdf_word_position(pdf, 1, 'Theme')
      assert_in_delta(34, left, 2, 'left of the text of the cover')
      assert_in_delta(34, top, 15, 'top of the text of the cover')
      cover = Open3.capture2('pdftotext', '-f', '1', '-l', '1', pdf.to_s, '-').first
      ['Theme cover', 'Sample document', 'Sample subtitle', 'Sample Author'].each { |expected| assert_includes(cover, expected) }
      assert_includes(pdf_text(pdf), 'End of document')
    end
  end

  def test_typst_theme_cover
    require_command('typst')
    check_theme_cover('typst')
  end

  def test_latex_theme_cover
    require_command('lualatex')
    check_theme_cover('latex')
  end

  def test_html
    with_fixtures do |dir|
      html = dir / 'sample.html'
      Gfm2Pdf.markdown_to_html(md: dir / 'sample.md', html: html)
      content = html.read
      assert_includes(content, '<div class="admonition note">')
      assert_includes(content, 'Hello from the sample')
      # embed-resources: the image is in the HTML
      assert_includes(content, 'src="data:image/svg+xml;base64,')
    end
  end

  # Version of the toolchain in a Makefile, and check of the version required by the project
  def test_make_version
    require_command('make')
    with_fixtures do |dir|
      (dir / 'Makefile').write(<<~MAKEFILE)
        include #{ROOT}/pandoc.mak
        show-version:
        \t@echo "version=$(GFM2PDF_VERSION)"
      MAKEFILE
      make = ->(*args) { Open3.capture2e('make', *args, chdir: dir.to_s) }
      out, status = make.call('show-version')
      assert(status.success?, out)
      assert_equal("version=#{Gfm2Pdf::VERSION}\n", out)
      out, status = make.call('show-version', "GFM2PDF_VERSION_REQUIRED=>= #{Gfm2Pdf::VERSION}")
      assert(status.success?, out)
      out, status = make.call('show-version', 'GFM2PDF_VERSION_REQUIRED=~> 999.0')
      refute(status.success?)
      assert_includes(out, 'does not meet the required version: ~> 999.0')
    end
  end

  def test_make
    require_command('make')
    require_command('lualatex')
    with_fixtures do |dir|
      (dir / 'Makefile').write(<<~MAKEFILE)
        GFM2PDF_HOME = #{ROOT}
        include $(GFM2PDF_HOME)/pandoc.mak
        all: sample.pdf
        other.pdf: GFM2PDF_ENGINE = typst
        show-dir:
        \t@echo "dir=$(GFM2PDF_HOME)"
        show-deps:
        \t@echo "$(GFM2PDF_DEPS)"
      MAKEFILE
      make = ->(*args) { Open3.capture2e('make', *args, chdir: dir.to_s) }
      out, status = make.call
      assert(status.success?, out)
      assert_includes(pdf_text(dir / 'sample.pdf'), 'Sample document')
      # nothing to do when up to date
      out, status = make.call
      assert(status.success?, out)
      assert_includes(out, 'Nothing to be done')
      # modes check and fix: also the documents up to date
      out, status = make.call('-n', 'GFM2PDF_MODE=check')
      assert(status.success?, out)
      assert_match(%r{^GFM2PDF_ENGINE=latex GFM2PDF_THEME= GFM2PDF_MODE=check ruby \S+/lib/pandoc.rb pdf sample.md sample.pdf$}, out)
      # engine per target
      FileUtils.cp(dir / 'sample.md', dir / 'other.md')
      out, status = make.call('-n', 'other.pdf')
      assert(status.success?, out)
      assert_match(%r{^GFM2PDF_ENGINE=typst GFM2PDF_THEME= GFM2PDF_MODE=build ruby \S+/lib/pandoc.rb pdf other.md other.pdf$}, out)
      # theme: given to pandoc.rb, its files are dependencies
      out, status = make.call('-n', 'other.pdf', 'GFM2PDF_THEME=theme')
      assert(status.success?, out)
      assert_match(/^GFM2PDF_ENGINE=typst GFM2PDF_THEME=theme GFM2PDF_MODE=build ruby /, out)
      out, status = make.call('show-deps', 'GFM2PDF_THEME=theme')
      assert(status.success?, out)
      assert_match(%r{/theme/cover\.tex\b}, out)
      # the variable of the Makefile is not changed by pandoc.mak
      out, status = make.call('show-dir')
      assert(status.success?, out)
      assert_equal("dir=#{ROOT}\n", out)
    end
  end
end
