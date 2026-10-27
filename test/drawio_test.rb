# frozen_string_literal: true

require_relative 'test_helper'
require_relative '../lib/drawio'

# lib/drawio.rb, without draw.io desktop
class DrawioTest < Minitest::Test
  include TestHelper

  def drawio(*args, chdir: FIXTURES)
    Open3.capture3('ruby', (ROOT / 'lib/drawio.rb').to_s, *args, chdir: chdir.to_s)
  end

  def test_list_images_named_after_tabs
    out, err, status = drawio('list', 'diagrams.drawio', 'svg')
    assert(status.success?, err)
    assert_equal("topology.svg\nflow.svg\n", out)
  end

  def test_list_images_in_folder_of_drawio_file
    out, _err, status = drawio('list', 'fixtures/diagrams.drawio', 'png', chdir: FIXTURES.parent)
    assert(status.success?)
    assert_equal("fixtures/topology.png\nfixtures/flow.png\n", out)
  end

  def test_usage
    _out, err, status = drawio
    refute(status.success?)
    assert_includes(err, 'Usage:')
  end

  def test_svg_text_warning_removed
    svg = '<svg><g/><switch><g requiredFeatures="http://www.w3.org/TR/SVG11/feature#Extensibility"/>' \
      '<a transform="translate(0,-5)" xlink:href="https://www.drawio.com/doc/faq/svg-export-text-problems" target="_blank">' \
      '<text text-anchor="middle" font-size="10px" x="50%" y="100%">Text is not SVG - cannot display</text></a></switch></svg>'
    assert_equal('<svg><g/></svg>', svg.sub(SVG_TEXT_WARNING, ''))
  end

  def test_make_images_with_pdf_for_svg
    require_command('make')
    with_fixtures do |dir|
      (dir / 'Makefile').write(<<~MAKEFILE)
        DRAWIO_FILE = diagrams.drawio
        include #{ROOT}/drawio.mak
        show:
        \t@echo $(DRAWIO_IMAGES)
      MAKEFILE
      make = ->(*args) { Open3.capture2e('make', *args, chdir: dir.to_s) }
      out, status = make.call('show')
      assert(status.success?, out)
      assert_equal("topology.svg flow.svg topology.pdf flow.pdf\n", out)
      out, status = make.call('-n', 'topology.pdf')
      assert(status.success?, out)
      assert_match(%r{^ruby \S+/lib/drawio.rb export diagrams.drawio topology.pdf --scale 2$}, out)
      out, status = make.call('show', 'DRAWIO_FORMAT=png')
      assert(status.success?, out)
      assert_equal("topology.png flow.png\n", out)
    end
  end

  # With draw.io desktop: the PDF is cropped to the diagram, with the text of the HTML labels
  def test_export_pdf
    skip('draw.io desktop not found') if drawio_path.nil?
    require_command('pdfinfo')
    with_fixtures do |dir|
      _out, err, status = drawio('export', 'diagrams.drawio', 'topology.pdf', chdir: dir)
      assert(status.success?, err)
      pdf = dir / 'topology.pdf'
      assert_equal('Client ascli', pdf_text(pdf).strip)
      info, = Open3.capture2('pdfinfo', pdf.to_s)
      width = info[/^Page size:\s+([\d.]+)/, 1].to_f
      assert_operator(width, :<, 200, 'cropped to the diagram')
    end
  end
end
