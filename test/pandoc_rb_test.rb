# frozen_string_literal: true

require_relative 'test_helper'
require 'yaml'

# Functions of lib/pandoc.rb, without PDF engine
class PandocRbTest < Minitest::Test
  include TestHelper

  # Markdown file in a temporary folder
  # @param content [String] Markdown
  # @yieldparam md [Pathname]
  def with_markdown(content)
    Dir.mktmpdir do |dir|
      md = Pathname.new(dir) / 'doc.md'
      md.write(content)
      yield(md)
    end
  end

  def test_comment_options
    options = YAML.safe_load(Gfm2Pdf.comment_options(FIXTURES / 'sample.md'))
    assert_equal({'common' => {'metadata' => {'subtitle' => 'Sample subtitle', 'author' => 'Sample Author'}}}, options)
    assert_nil(Gfm2Pdf.comment_options(FIXTURES / 'broken_link.md'))
  end

  # A comment in a code block is an example, not the options of the document
  def test_comment_options_in_code_block
    with_markdown("# Doc\n\n````markdown\n```\n<!-- gfm2pdf\ncommon:\n-->\n```\n````\n\n~~~\nPANDOC_DEFAULTS_BEGIN\n~~~\n") do |md|
      assert_nil(Gfm2Pdf.comment_options(md))
    end
  end

  def test_comment_options_errors
    with_markdown("# Doc\n<!-- gfm2pdf\ncommon:\n") do |md|
      assert_includes(assert_raises(RuntimeError) { Gfm2Pdf.comment_options(md) }.message, 'not closed by a line `-->`')
    end
    with_markdown("# Doc\n<!--\nPANDOC_DEFAULTS_BEGIN\nmetadata:\nPANDOC_DEFAULTS_END\n-->\n") do |md|
      assert_includes(assert_raises(RuntimeError) { Gfm2Pdf.comment_options(md) }.message, 'doc.md:3: PANDOC_DEFAULTS_BEGIN is no longer supported')
    end
  end

  def test_options_file
    assert_equal(FIXTURES / 'sample.gfm2pdf.yaml', Gfm2Pdf.options_file(FIXTURES / 'sample.md'))
  end

  def test_parse_options
    folder = Pathname.new('/docs')
    options = Gfm2Pdf.parse_options("common:\n  metadata:\n    date: 2026-01-15\nlatex:\n  include-before-body:\n    - ${.}/preface.tex\npdf:\n", 'test', folder)
    assert_equal({'common' => {'metadata' => {'date' => Date.new(2026, 1, 15)}}, 'latex' => {'include-before-body' => ['/docs/preface.tex']}}, options)
    assert_empty(Gfm2Pdf.parse_options('', 'test', folder))
    {
      "latx:\n  toc: false\n"     => 'test: unknown section: latx, expected: common, pdf, html, latex, typst',
      "metadata:\n  author: Me\n" => 'test: unknown section: metadata',
      "- common\n"                => 'test: expected a map of sections',
      "common: true\n"            => 'test: section common: expected a map of pandoc defaults',
      "common: [\n"               => 'test: '
    }.each do |yaml, message|
      assert_includes(assert_raises(RuntimeError) { Gfm2Pdf.parse_options(yaml, 'test', folder) }.message, message)
    end
  end

  # Options of the document: comment, then file, each: common, then output, then engine
  def test_document_options_order
    with_markdown("# Doc\n<!-- gfm2pdf\ncommon:\n  toc: false\ntypst:\n  toc: false\n-->\n") do |md|
      Gfm2Pdf.options_file(md).write("common:\n  toc: true\npdf:\n  toc: true\nlatex:\n  toc: true\nhtml:\n  toc: true\n")
      names = ->(output, engine) { Gfm2Pdf.with_source(md, output, engine) { |_source, defaults, _tmp| defaults.drop(2).map { |f| f.basename.to_s } } }
      assert_equal(%w[options0.common.yaml options0.typst.yaml options1.common.yaml options1.pdf.yaml], names.call('pdf', 'typst'))
      assert_equal(%w[options0.common.yaml options1.common.yaml options1.pdf.yaml options1.latex.yaml], names.call('pdf', 'latex'))
      assert_equal(%w[options0.common.yaml options1.common.yaml options1.html.yaml], names.call('html', nil))
      # generated files are pandoc defaults
      Gfm2Pdf.with_source(md, 'pdf', 'latex') do |_source, defaults, _tmp|
        assert_equal({'toc' => true}, YAML.safe_load(defaults.last.read))
      end
    end
  end

  def test_convert_img_for_pandoc
    assert_equal('See ![Logo](images/logo.png).', Gfm2Pdf.convert_img_for_pandoc('See <img src="images/logo.png" alt="Logo" width="50"/>.'))
    assert_equal('![](a.svg)', Gfm2Pdf.convert_img_for_pandoc("<img src='a.svg'>"))
  end

  def test_dependencies
    deps = Gfm2Pdf.dependencies(nil)
    %w[common/defaults.yaml latex/pdf_in_header.tex typst/report.typ lib/pandoc.rb].each do |file|
      assert_includes(deps, ROOT / file)
    end
    assert(deps.all?(&:file?))
    assert_includes(Gfm2Pdf.dependencies(FIXTURES / 'theme'), FIXTURES / 'theme/cover.typ')
  end

  def test_default_theme
    saved = ENV.delete('GFM2PDF_THEME')
    assert_nil(Gfm2Pdf.default_theme)
    ENV['GFM2PDF_THEME'] = ''
    assert_nil(Gfm2Pdf.default_theme)
    ENV['GFM2PDF_THEME'] = 'theme'
    assert_equal('theme', Gfm2Pdf.default_theme)
  ensure
    ENV['GFM2PDF_THEME'] = saved
  end

  def test_theme_not_found
    error = assert_raises(ArgumentError) { Gfm2Pdf.markdown_to_pdf(md: FIXTURES / 'sample.md', pdf: 'out.pdf', theme: FIXTURES / 'missing') }
    assert_includes(error.message, 'Theme folder not found')
  end

  # The options of the theme come after the ones of the toolchain, and before the ones of the document
  def test_theme_defaults
    theme = FIXTURES / 'theme'
    Gfm2Pdf.with_source(FIXTURES / 'sample.md', 'pdf', 'typst', theme: theme) do |_source, defaults, tmp|
      assert_equal([ROOT / 'common/defaults.yaml', ROOT / 'typst/defaults.yaml', theme / 'typst.yaml', tmp / 'options0.common.yaml'], defaults)
    end
    # the theme has no options for HTML
    Gfm2Pdf.with_source(FIXTURES / 'broken_link.md', 'html', theme: theme) do |_source, defaults, _tmp|
      assert_equal([ROOT / 'common/defaults.yaml', ROOT / 'html/defaults.yaml'], defaults)
    end
  end

  def test_change_time_outside_git
    Dir.mktmpdir do |dir|
      md = Pathname.new(dir) / 'doc.md'
      md.write('# Doc')
      assert_equal(md.mtime, Gfm2Pdf.change_time(md))
    end
  end

  def test_default_engine
    saved = ENV.delete('GFM2PDF_ENGINE')
    assert_equal('latex', Gfm2Pdf.default_engine)
    ENV['GFM2PDF_ENGINE'] = 'typst'
    assert_equal('typst', Gfm2Pdf.default_engine)
  ensure
    ENV['GFM2PDF_ENGINE'] = saved
  end

  def test_unknown_engine
    error = assert_raises(ArgumentError) { Gfm2Pdf.markdown_to_pdf(md: FIXTURES / 'sample.md', pdf: 'out.pdf', engine: 'word') }
    assert_includes(error.message, 'latex, typst')
  end

  def test_check_anchors
    Gfm2Pdf.check_markdown_anchors(FIXTURES / 'sample.md')
    level = Gfm2Pdf.log.level
    Gfm2Pdf.log.level = :fatal
    error = assert_raises(RuntimeError) { Gfm2Pdf.check_markdown_anchors(FIXTURES / 'broken_link.md') }
    # both on GitHub and in the PDF
    assert_includes(error.message, '2 broken internal link(s)')
  ensure
    Gfm2Pdf.log.level = level
  end

  def test_version
    assert_match(/\A\d+\.\d+\.\d+(\.pre)?\z/, Gfm2Pdf::VERSION)
    assert_equal(Gfm2Pdf::VERSION, (ROOT / 'VERSION').read.strip)
  end

  def test_check_version
    Gfm2Pdf.check_version(">= #{Gfm2Pdf::VERSION}")
    Gfm2Pdf.check_version('>= 0.1, < 999')
    error = assert_raises(RuntimeError) { Gfm2Pdf.check_version('~> 999.0') }
    assert_includes(error.message, "gfm2pdf-toolchain #{Gfm2Pdf::VERSION}")
    assert_raises(ArgumentError) { Gfm2Pdf.check_version('latest') }
  end

  def test_cli_version
    out, _err, status = Open3.capture3('ruby', (ROOT / 'lib/pandoc.rb').to_s, 'version')
    assert(status.success?)
    assert_equal("#{Gfm2Pdf::VERSION}\n", out)
    out, err, status = Open3.capture3('ruby', (ROOT / 'lib/pandoc.rb').to_s, 'version', '~> 999.0')
    refute(status.success?)
    assert_empty(out)
    assert_includes(err, 'does not meet the required version: ~> 999.0')
  end

  def test_cli_usage
    _out, err, status = Open3.capture3('ruby', (ROOT / 'lib/pandoc.rb').to_s)
    refute(status.success?)
    assert_includes(err, 'Usage: pandoc.rb <command> [arguments]')
  end
end
