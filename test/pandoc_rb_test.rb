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

  def test_download_images
    Dir.mktmpdir do |dir|
      folder = Pathname.new(dir) / 'images'
      calls = []
      # No network in tests
      Gfm2Pdf.define_singleton_method(:http_get) do |url, *|
        calls << url
        ['PNG', 'image/png']
      end
      text = Gfm2Pdf.download_images('![a](https://x.test/a.png) ![b](https://x.test/b?id=1) ![c](https://x.test/a.png) ![d](local.png)', folder)
      files = text.scan(/\(([^)]+)\)/).flatten
      assert_equal(['https://x.test/a.png', 'https://x.test/b?id=1'], calls)
      assert_equal(files[0], files[2])
      assert(files[0].end_with?('.png'))
      assert(files[1].end_with?('.png'), 'extension from the media type')
      assert_equal('local.png', files[3])
      assert_equal('PNG', Pathname.new(files[0]).read)
    ensure
      Gfm2Pdf.singleton_class.send(:remove_method, :http_get)
    end
  end

  DIAGRAM = "sequenceDiagram\n    title My flow\n    A->>B: hello\n"

  # Only the diagrams that GitHub shows: not a block inside another one, not another language
  def test_replace_mermaid
    markdown = <<~MARKDOWN
      Text.

      ```mermaid
      #{DIAGRAM.chomp}
      ```

      ````markdown
      ```mermaid
      graph TD
      ```
      ````

      ```ruby
      puts 1
      ```

      - item

        ~~~mermaid
        graph LR
          A --> B
        ~~~

      ```mermaid
      graph TD
    MARKDOWN
    found = []
    after = Gfm2Pdf.replace_mermaid(markdown) { |indent, diagram, _| (found << [indent, diagram]).then { "#{indent}[diagram #{found.length}]\n" } }
    assert_equal([['', DIAGRAM], ['  ', "graph LR\n  A --> B\n"]], found)
    assert_equal(markdown.sub(/```mermaid\n#{Regexp.escape(DIAGRAM)}```/, '[diagram 1]').sub(/  ~~~mermaid.*?~~~/m, '  [diagram 2]'), after)
    assert_equal('', Gfm2Pdf.replace_mermaid('') { raise 'no block' })
  end

  def test_mermaid_title
    assert_equal('My flow', Gfm2Pdf.mermaid_title(DIAGRAM))
    assert_equal('A title', Gfm2Pdf.mermaid_title("---\ntitle: A title\n---\ngraph TD\n"))
    assert_equal('', Gfm2Pdf.mermaid_title("graph TD\n  A --> B\n"))
  end

  # Fake Mermaid CLI: copies the diagram to the output file, with the options of mmdc
  def with_fake_mmdc
    Dir.mktmpdir do |dir|
      script = Pathname.new(dir) / 'mmdc'
      script.write("#!/bin/sh\nwhile [ $# -gt 0 ]; do case \"$1\" in -i) i=$2; shift;; -o) o=$2; shift;; esac; shift; done\necho \"rendered\" > \"$o\"; cat \"$i\" >> \"$o\"\n")
      script.chmod(0o755)
      old = ENV.fetch('GFM2PDF_MMDC', nil)
      ENV['GFM2PDF_MMDC'] = script.to_s
      yield(Pathname.new(dir) / 'images')
    ensure
      old ? ENV['GFM2PDF_MMDC'] = old : ENV.delete('GFM2PDF_MMDC')
    end
  end

  def test_render_mermaid
    with_fake_mmdc do |folder|
      text = Gfm2Pdf.render_mermaid("A\n\n```mermaid\n#{DIAGRAM}```\n\n- b\n\n  ```mermaid\n  #{DIAGRAM.gsub("\n", "\n  ").rstrip}\n  ```\n\n```mermaid\ngraph TD\n```\n", folder, 'pdf')
      images = text.scan(/^( *)!\[([^\]]*)\]\(([^)]+)\)$/)
      assert_equal(3, images.length)
      assert_equal([['', 'My flow'], ['  ', 'My flow'], ['', '']], images.map { |i| i[0..1] })
      assert_equal(images[0][2], images[1][2], 'same diagram, same image')
      assert_equal(2, folder.glob('*.pdf').length)
      assert_equal("rendered\n#{DIAGRAM}", Pathname.new(images[0][2]).read)
      assert_equal(Pathname.new(images[0][2]).sub_ext('.mmd').read, DIAGRAM)
      svg = Gfm2Pdf.render_mermaid("```mermaid\ngraph TD\n```\n", folder, 'svg')
      assert_match(/\(.*mermaid-\h+\.svg\)/, svg)
      assert_equal("no diagram\n", Gfm2Pdf.render_mermaid("no diagram\n", folder, 'pdf'))
    end
  end

  def test_render_mermaid_not_found
    ENV['GFM2PDF_MMDC'] = '/nonexistent/mmdc -q'
    Dir.mktmpdir do |dir|
      error = assert_raises(RuntimeError) { Gfm2Pdf.render_mermaid("```mermaid\ngraph TD\n```\n", Pathname.new(dir), 'pdf') }
      assert_match(/mmdc not found: install Mermaid CLI/, error.message)
      # no diagram: no need of the command
      assert_equal("text\n", Gfm2Pdf.render_mermaid("text\n", Pathname.new(dir), 'pdf'))
    end
  ensure
    ENV.delete('GFM2PDF_MMDC')
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

  def test_default_mode
    saved = ENV.delete('GFM2PDF_MODE')
    assert_equal('build', Gfm2Pdf.default_mode)
    ENV['GFM2PDF_MODE'] = 'check'
    assert_equal('check', Gfm2Pdf.default_mode)
  ensure
    ENV['GFM2PDF_MODE'] = saved
  end

  def test_unknown_mode
    with_markdown("Text.\n") do |md|
      error = assert_raises(ArgumentError) { Gfm2Pdf.markdown_to_html(md: md, html: md.sub_ext('.html'), mode: 'chek') }
      assert_includes(error.message, 'Unknown mode: chek, expected one of: build, check, fix')
    end
  end

  # Generate HTML from the Markdown in a mode, quietly, with image `x.png` next to it, and an older HTML file
  # @yieldparam md    [Pathname] Markdown file, after the generation
  # @yieldparam html  [Pathname] HTML file
  # @yieldparam error [StandardError, nil] Error of the generation
  def html_in_mode(markdown, mode)
    level = Gfm2Pdf.log.level
    Gfm2Pdf.log.level = :fatal
    with_markdown(markdown) do |md|
      FileUtils.cp(FIXTURES / 'theme/cover.png', md.dirname / 'x.png')
      html = md.sub_ext('.html')
      html.write('older')
      error = nil
      # warnings of pandoc
      capture_subprocess_io do
        Gfm2Pdf.markdown_to_html(md: md, html: html, mode: mode)
      rescue StandardError => e
        error = e
      end
      yield(md, html, error)
    end
  ensure
    Gfm2Pdf.log.level = level
  end

  GAP = "![x](x.png)\n\n*Figure 2: x*\n"

  def test_mode_build
    html_in_mode(GAP, 'build') do |_md, html, error|
      assert_nil(error)
      assert_includes(html.read, 'Figure 2: x</figcaption>')
    end
  end

  def test_mode_check
    html_in_mode("![x](x.png)\n\n*Figure 1: x*\n\nSee Figure 1.\n", 'check') do |_md, html, error|
      assert_nil(error)
      assert_includes(html.read, '<a href="#fig-1">')
    end
    # a warning, or an internal link without heading: an error, and no output, not even the older one
    [GAP, "See [details](#details).\n"].each do |markdown|
      html_in_mode(markdown, 'check') do |_md, html, error|
        assert_kind_of(RuntimeError, error, markdown)
        refute_path_exists(html, markdown)
      end
    end
  end

  def test_mode_fix
    html_in_mode("#{GAP}\nSee Figure 2.\n", 'fix') do |md, html, error|
      assert_nil(error)
      assert_equal("![x](x.png)\n\n*Figure 1: x*\n\nSee Figure 1.\n", md.read)
      assert_includes(html.read, 'Figure 1: x</figcaption>')
    end
    # cannot be fixed (caption in code): generated anyway
    html_in_mode("Text.\n\n    ![x](x.png)\n\n    *Figure 2: in code*\n", 'fix') do |_md, html, error|
      assert_nil(error)
      assert_includes(html.read, 'Figure 2: in code')
    end
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

  # Renumber the figures of the Markdown, quietly
  # @return [Array(String, Array<String>, Array<String>)] Markdown after, changes and mentions not renumbered
  def renumber(markdown)
    level = Gfm2Pdf.log.level
    Gfm2Pdf.log.level = :fatal
    with_markdown(markdown) do |md|
      changes, skipped = Gfm2Pdf.renumber_figures(md)
      [md.read, changes.map { |c| c.delete_prefix("#{md}:") }, skipped.map { |s| s.delete_prefix("#{md}:") }]
    end
  ensure
    Gfm2Pdf.log.level = level
  end

  # A figure added with a number not used yet: the captions and mentions after it follow
  RENUMBER_BEFORE = <<~MARKDOWN
    See Figure 2, Figure 0 and figure
    3.

    ![a](a.png)

    *Figure 1: a*

    ![new](n.png)

    *Figure 0: new, unlike Figure 1*

    - item

      ![b](b.png)

      > Figure 2: b

    ![Figure 3: alt](c.png)

    Not: `Figure 2`, Figure 2 of RFC 1234, Figure 2.1, Subfigure 2.

    ```text
    Figure 2
    ```

    <!-- Figure 2 -->
  MARKDOWN

  def test_renumber_figures
    after, changes, skipped = renumber(RENUMBER_BEFORE)
    expected = {
      'Figure 2, Figure 0 and figure' => 'Figure 3, Figure 2 and figure',
      "\n3."                          => "\n4.",
      'Figure 0: new'                 => 'Figure 2: new',
      '> Figure 2: b'                 => '> Figure 3: b',
      '![Figure 3: alt]'              => '![Figure 4: alt]'
    }.reduce(RENUMBER_BEFORE) { |text, (from, to)| text.sub(from, to) }
    assert_equal(expected, after)
    assert_equal(
      ['1: Figure 2 -> Figure 3', '1: Figure 0 -> Figure 2', '2: Figure 3 -> Figure 4', '10: Figure 0 -> Figure 2', '16: Figure 2 -> Figure 3', '18: Figure 3 -> Figure 4'],
      changes
    )
    assert_empty(skipped)
    # numbered: nothing to change, and the filter agrees
    assert_equal([after, [], []], renumber(after))
    assert_empty(pandoc_warnings(after, 'html', 'native').last)
  end

  # Mentions of a number of several figures, or of none: not renumbered
  def test_renumber_figures_ambiguous
    markdown = "![a](a.png)\n\n*Figure 1: a*\n\n![b](b.png)\n\n*Figure 1: b*\n\nSee Figure 1 and Figure 9.\n"
    after, changes, skipped = renumber(markdown)
    assert_equal(markdown.sub('Figure 1: b', 'Figure 2: b'), after)
    assert_equal(['7: Figure 1 -> Figure 2'], changes)
    assert_equal(['9: Figure 1 not renumbered: several figures have this number', '9: Figure 9 not renumbered: no figure has this number'], skipped)
  end

  # Caption `Figure 2` of code, between figures 1 and 3: not renumbered, it would refer to figure 3 renumbered 2
  def test_renumber_figures_mention_taken
    markdown = "![a](a.png)\n\n*Figure 1: a*\n\n```yaml\nkey: value\n```\n\n*Figure 2: code*\n\n![b](b.png)\n\n*Figure 3: b*\n\nSee Figure 2 and Figure 3.\n"
    with_markdown(markdown) do |md|
      error = assert_raises(RuntimeError) { Gfm2Pdf.renumber_figures(md) }
      assert_includes(error.message, "#{md}: not changed, mentions that would refer to another figure: line 9: Figure 2, line 15: Figure 2.")
      assert_includes(error.message, 'Change them by hand (e.g. `Listing` for a caption of code), then renumber')
      assert_equal(markdown, md.read)
    end
    # renamed: renumbered
    after, changes, skipped = renumber(markdown.gsub('Figure 2', 'Listing 1'))
    assert_includes(after, "*Figure 2: b*\n\nSee Listing 1 and Figure 2.\n")
    assert_equal(2, changes.length)
    assert_empty(skipped)
  end

  # Same captions as common/figure_caption.lua, also HTML images and alt text
  def test_renumber_figures_caption_forms
    forms = MANUAL_CAPTIONS.merge(
      'html image' => "<img src=\"x.png\" alt=\"Alt text\">\n\n*Figure 1: Manual caption*\n",
      'alt text'   => "![Figure 1: Manual caption](x.png)\n"
    )
    forms.each do |form, markdown|
      after, changes, = renumber(markdown.sub('Figure 1', 'Figure 5'))
      assert_equal(markdown, after, form)
      assert_equal(1, changes.length, form)
    end
  end

  # A diagram is an image: its manual caption is renumbered too
  def test_renumber_figures_mermaid
    markdown = "```mermaid\n#{DIAGRAM}```\n\n*Figure 5: Flow*\n\n![a](a.png)\n\n*Figure 9: a*\n\nSee Figure 9.\n"
    after, changes, skipped = renumber(markdown)
    assert_equal(markdown.sub('Figure 5', 'Figure 1').sub('Figure 9: a', 'Figure 2: a').sub('See Figure 9', 'See Figure 2'), after)
    assert_equal(3, changes.length)
    assert_empty(skipped)
  end

  # Inline code on two lines; a stray backtick does not start inline code up to the next paragraphs
  def test_renumber_figures_inline_code
    markdown = "A stray ` backtick.\n\n![x](x.png)\n\n*Figure 2: x*\n\nSee Figure 2, not `Figure\n2`.\n"
    after, changes, = renumber(markdown)
    assert_equal("A stray ` backtick.\n\n![x](x.png)\n\n*Figure 1: x*\n\nSee Figure 1, not `Figure\n2`.\n", after)
    assert_equal(2, changes.length)
  end

  # A caption in an indented code block: pandoc and the text disagree, the file is not changed
  def test_renumber_figures_not_found
    markdown = "Text.\n\n    ![x](x.png)\n\n    *Figure 2: in code*\n"
    with_markdown(markdown) do |md|
      error = assert_raises(RuntimeError) { Gfm2Pdf.renumber_figures(md) }
      assert_includes(error.message, 'figures of pandoc () not found in the text (2), renumber them by hand')
      assert_equal(markdown, md.read)
    end
  end

  def test_cli_renumber_figures
    with_markdown("![x](x.png)\n\n*Figure 2: x*\n\nSee Figure 2.\n") do |md|
      _out, err, status = Open3.capture3({'GFM2PDF_LOG_LEVEL' => 'info'}, 'ruby', (ROOT / 'lib/pandoc.rb').to_s, 'renumber-figures', md.to_s)
      assert(status.success?, err)
      assert_includes(err, "#{md}:3: Figure 2 -> Figure 1")
      assert_equal("![x](x.png)\n\n*Figure 1: x*\n\nSee Figure 1.\n", md.read)
    end
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
