# frozen_string_literal: true

require_relative 'test_helper'

# Lua filters and pandoc options, without PDF engine
class FiltersTest < Minitest::Test
  include TestHelper

  ALERT = "> [!WARNING]\n> Use `--transfer=direct` here.\n"
  WIDE_TABLE = <<~MARKDOWN
    | Field | Type | Description |
    | --- | --- | --- |
    | `download_partial_suffix` | `String` | File suffix appended to the target filename while a download is in progress, removed at the end.<br/>Default: `.partial`. |
  MARKDOWN

  # Relative column widths of the LaTeX tables
  def latex_widths(latex)
    latex.scan(/\\real\{([0-9.]+)\}/).flatten.map(&:to_f)
  end

  def test_admonition_latex
    latex = pandoc(ALERT, 'latex', 'latex')
    assert_includes(latex, '\begin{tcolorbox}[enhanced, breakable, colback=red!5')
    assert_includes(latex, 'title={\faExclamationTriangle\ Warning}')
    # the body stays in the document: code_break.lua processes it
    assert_includes(latex, '\texttt{-\nobreak{}-\nobreak{}transfer=\allowbreak{}direct}')
  end

  def test_admonition_typst
    typst = pandoc("> [!NOTE]\n> Body *text*.\n", 'typst', 'typst')
    assert_match(/#admonition\("note", "ℹ️", "Note"\)\[\nBody #emph\[text\]\.\n\n\]/, typst)
  end

  def test_admonition_html
    html = pandoc("> [!TIP]\n> Body.\n", 'html', 'html5')
    assert_includes(html, %Q(<div class="admonition tip">\n<div class="admonition-title">💡 Tip</div>))
    assert_includes(html, "<p>Body.</p>\n</div>\n</div>")
  end

  # Tag alone in its paragraph, e.g. followed by an empty line, required before a list: no empty paragraph in the box
  def test_admonition_tag_alone
    native = pandoc("> [!NOTE]\n>\n> - item one\n> - item two\n", 'html', 'native')
    assert_includes(native, '( "" , [ "note" ] , [] )')
    assert_includes(native, 'BulletList')
    refute_includes(native, 'Para []')
  end

  def test_quote_without_alert
    html = pandoc("> Just a quote.\n", 'html', 'html5')
    assert_includes(html, "<blockquote>\n<p>Just a quote.</p>\n</blockquote>")
  end

  def test_line_break_in_table_cell
    assert_includes(pandoc(WIDE_TABLE, 'typst', 'typst'), 'end. \ Default: `.partial`.')
  end

  def test_no_short_subscripts
    native = pandoc("Wait ~600 ms in ~/.ssh, but H~2~O.\n", 'html', 'native')
    assert_includes(native, 'Str "~600"')
    assert_includes(native, 'Str "~/.ssh,"')
    assert_includes(native, 'Subscript [ Str "2" ]')
  end

  def test_code_break_not_in_heading
    latex = pandoc("## Folder `a/b`\n\nText `a/b`.\n", 'latex', 'latex')
    # PDF bookmarks keep the text of the heading
    assert_includes(latex, '\texttt{a/b}}{Folder a/b}')
    assert_includes(latex, 'Text \texttt{a/\allowbreak{}b}.')
  end

  def test_table_widths_from_content
    widths = latex_widths(pandoc(WIDE_TABLE, 'latex', 'latex'))
    assert_equal(3, widths.length)
    assert_in_delta(1.0, widths.sum, 0.001)
    # inline code is measured: the field name fits on one line
    assert_operator(widths[0], :>, widths[1])
    assert_operator(widths[2], :>, widths[0])
  end

  def test_table_widths_tuned_separator
    table = WIDE_TABLE.sub('| --- | --- | --- |', '| ------ | -------------- | ------------------------------------ |')
    widths = latex_widths(pandoc(table, 'latex', 'latex'))
    assert_equal(3, widths.length)
    assert_operator(widths[1], :>, widths[0])
    assert_operator(widths[2], :>, widths[1])
  end

  # PDF output: the PDF next to an SVG image is used instead
  def test_pdf_instead_of_svg
    with_fixtures do |dir|
      Dir.chdir(dir) do
        assert_includes(pandoc('![Logo](image.svg)', 'typst', 'typst'), 'image("image.svg"')
        (dir / 'image.pdf').write('')
        assert_includes(pandoc('![Logo](image.svg)', 'typst', 'typst'), 'image("image.pdf"')
        assert_includes(pandoc('![Logo](image.svg)', 'latex', 'latex'), '{image.pdf}')
        assert_includes(pandoc('![Logo](image.svg)', 'html', 'html5'), 'src="data:image/svg+xml;base64,')
      end
    end
  end

  # Forms of a manual caption after an image, as shown by GitHub
  MANUAL_CAPTIONS = {
    'italic'         => "![Alt text](x.png)\n\n*Figure 1: Manual caption*\n",
    'plain'          => "![Alt text](x.png)\n\nFigure 1: Manual caption\n",
    'quote'          => "![Alt text](x.png)\n\n> Figure 1: Manual caption\n",
    'quote, no line' => "![Alt text](x.png)\n> Figure 1: Manual caption\n",
    'next line'      => "![Alt text](x.png)\n*Figure 1: Manual caption*\n",
    'no alt text'    => "![](x.png)\n\n*Figure 1: Manual caption*\n",
    'in a list'      => "- item\n\n  ![Alt text](x.png)\n\n  *Figure 1: Manual caption*\n"
  }.freeze

  # The manual caption replaces the alt text as caption, and is not in the body
  def test_figure_manual_caption
    MANUAL_CAPTIONS.each do |form, markdown|
      latex = pandoc(markdown, 'latex', 'latex')
      assert_includes(latex, '\caption{Figure 1: Manual caption}', form)
      assert_equal(1, latex.scan('Manual caption').length, form)
    end
  end

  def test_figure_manual_caption_typst_html
    typst = pandoc(MANUAL_CAPTIONS['italic'], 'typst', 'typst')
    assert_match(/caption: \[\s*Figure 1: Manual caption\s*\]/, typst)
    assert_equal(1, typst.scan('Manual caption').length)
    html = pandoc(MANUAL_CAPTIONS['italic'], 'html', 'html5')
    assert_includes(html, 'Figure 1: Manual caption</figcaption>')
    assert_equal(1, html.scan('Manual caption').length)
  end

  # Without manual caption, the caption is the alt text
  def test_figure_alt_caption
    latex = pandoc("![Alt text](x.png)\n\nText.\n", 'latex', 'latex')
    assert_includes(latex, '\caption{Alt text}')
    assert_includes(latex, "\nText.\n")
    # body text about a figure, not a caption
    latex = pandoc("![Alt text](x.png)\n\nFigure out the setup.\n", 'latex', 'latex')
    assert_includes(latex, '\caption{Alt text}')
    assert_includes(latex, "\nFigure out the setup.\n")
  end

  def test_table_auto_typst
    typst = pandoc(WIDE_TABLE, 'typst', 'typst')
    assert_includes(typst, 'columns: 3,')
    refute_match(/columns: \(.*%/, typst)
  end

  def test_table_auto_typst_tuned_separator
    table = WIDE_TABLE.sub('| --- | --- | --- |', '| ------ | -------------- | ------------------------------------ |')
    assert_match(/columns: \([0-9.]+%, [0-9.]+%, [0-9.]+%\)/, pandoc(table, 'typst', 'typst'))
  end
end
