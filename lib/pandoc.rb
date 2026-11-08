#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate PDF (with Typst or LuaLaTeX) or HTML from Markdown using pandoc, see README.md

require 'date'
require 'digest'
require 'fileutils'
require 'json'
require 'logger'
require 'net/http'
require 'open3'
require 'pathname'
require 'set'
require 'tmpdir'
require 'uri'
require 'yaml'

module Gfm2Pdf
  # Root folder of the toolchain
  ROOT = Pathname.new(__dir__).parent.freeze
  # Version of the toolchain: `x.y.z` for a release, `x.y.z.pre` between releases, see README.md
  VERSION = ROOT.join('VERSION').read.strip.freeze
  # PDF engines, the first one is the default
  PDF_ENGINES = %w[latex typst].freeze
  # Modes of generation, the first one is the default: build, check (a warning is an error), fix (fix the Markdown file
  # where possible, then build), see with_mode
  MODES = %w[build check fix].freeze
  # Folders with pandoc defaults, filters and templates
  DATA_FOLDERS = %w[common html latex typst].freeze
  # Sections of the options of a document, in the order they are applied: pandoc defaults for all outputs, for an
  # output, for a PDF engine
  OPTION_SECTIONS = %w[common pdf html latex typst].freeze
  # First line of the comment with the options of a document, in its Markdown file
  OPTIONS_COMMENT = '<!-- gfm2pdf'

  extend self

  # @return [Logger] Messages on stderr, level from env var `GFM2PDF_LOG_LEVEL` (default: `info`)
  def log
    @log ||= Logger.new($stderr, level: ENV.fetch('GFM2PDF_LOG_LEVEL', 'info'), formatter: proc { |severity, _time, _prog, msg| "#{severity}: #{msg}\n" })
  end

  # Execute a command (not in a shell)
  # @param cmd     [Array] Command and arguments
  # @param capture [Boolean] Return the standard output instead of displaying it
  # @return [String, nil] Standard output if `capture`
  # @raise [RuntimeError] if the command fails
  def run(*cmd, capture: false)
    cmd = cmd.map(&:to_s)
    log.info { "Executing: #{cmd.join(' ')}" }
    unless capture
      system(*cmd, exception: true)
      return
    end
    out, err, status = Open3.capture3(*cmd)
    raise "#{cmd.first}: #{err.strip}" unless status.success?
    out
  end

  # Files the generated documents depend on, e.g. for `make`
  # @param theme [String, Pathname, nil] Theme folder
  # @return [Array<Pathname>]
  def dependencies(theme = default_theme)
    files = ROOT.glob("{#{DATA_FOLDERS.join(',')}}/**/*").push(Pathname.new(__FILE__).expand_path)
    folder = theme_folder(theme)
    files.concat(folder.glob('**/*')) if folder
    files.select(&:file?)
  end

  # PDF engine from env var `GFM2PDF_ENGINE`, else the default one
  # @return [String]
  def default_engine
    ENV.fetch('GFM2PDF_ENGINE', PDF_ENGINES.first)
  end

  # Mode of generation from env var `GFM2PDF_MODE`, else the default one
  # @return [String]
  def default_mode
    ENV.fetch('GFM2PDF_MODE', MODES.first)
  end

  # Generate a document in a mode:
  # - `build`: generate it, warnings are displayed
  # - `check`: a warning is an error (pandoc, filters, PDF engine), and internal links must match a heading on GitHub
  #   too (check_markdown_anchors). A document that fails has no output, not even an older one.
  # - `fix`: renumber the figures of the Markdown file (renumber_figures), then generate it: what cannot be fixed stays
  #   a warning
  # @param md     [Pathname] Markdown file
  # @param output [Pathname] Generated document
  # @param mode   [String]   One of MODES
  # @yieldparam args [Array<String>] Pandoc arguments of the mode
  # @raise [ArgumentError] if the mode is unknown
  def with_mode(md, output, mode)
    raise ArgumentError, "Unknown mode: #{mode}, expected one of: #{MODES.join(', ')}" unless MODES.include?(mode)
    case mode
    when 'check'
      begin
        check_markdown_anchors(md)
        yield(['--fail-if-warnings'])
      rescue StandardError
        output.delete if output.exist?
        raise
      end
    when 'fix'
      begin
        renumber_figures(md)
      rescue RuntimeError => e
        log.warn(e.message)
      end
      yield([])
    else yield([])
    end
  end

  # Theme folder from env var `GFM2PDF_THEME`
  # @return [String, nil] nil if not set
  def default_theme
    theme = ENV.fetch('GFM2PDF_THEME', '')
    theme.empty? ? nil : theme
  end

  # Theme folder: cover, fonts, any pandoc option, see README.md
  # @param theme [String, Pathname, nil] Path to the theme folder
  # @return [Pathname, nil] Absolute path, nil if no theme
  # @raise [ArgumentError] if the folder does not exist
  def theme_folder(theme)
    return if theme.nil?
    folder = Pathname.new(theme).expand_path
    raise ArgumentError, "Theme folder not found: #{folder}" unless folder.directory?
    folder
  end

  # @param theme [Pathname, nil] Theme folder
  # @param name  [String]        File name
  # @return [Pathname, nil] File of the theme, nil if no theme or no such file
  def theme_file(theme, name)
    file = theme&.join(name)
    file if file&.exist?
  end

  # Options of a document in a comment of its Markdown file, outside code blocks: first line `<!-- gfm2pdf`, then YAML,
  # then a line `-->`
  # @param md [Pathname] Path to Markdown file
  # @return [String, nil] YAML, nil if none
  # @raise [RuntimeError] if the comment is not closed, or has the former syntax
  def comment_options(md)
    fence = nil
    lines = nil
    File.foreach(md).with_index(1) do |line, number|
      text = line.strip
      if lines
        return lines.join if text.eql?('-->')
        lines << line
        next
      end
      # Code block: from a fence to a fence of the same character, at least as long, alone on its line
      mark = text[/\A(`{3,}|~{3,})/, 1]
      if fence
        fence = nil if text.eql?(mark) && mark.start_with?(fence)
        next
      end
      fence = mark
      raise "#{md}:#{number}: PANDOC_DEFAULTS_BEGIN is no longer supported: use a comment `#{OPTIONS_COMMENT}` with the defaults in section `common:`, see README.md" if text.eql?('PANDOC_DEFAULTS_BEGIN')
      lines = [] if text.eql?(OPTIONS_COMMENT)
    end
    raise "#{md}: comment `#{OPTIONS_COMMENT}` not closed by a line `-->`" if lines
  end

  # @param md [Pathname] Path to Markdown file
  # @return [Pathname] File with the options of the document, next to it: `<name>.gfm2pdf.yaml` for `<name>.md`
  def options_file(md)
    md.dirname / "#{md.basename('.md')}.gfm2pdf.yaml"
  end

  # Options of a document, in the order they are applied: comment of its Markdown file, then file next to it
  # @param md [Pathname] Path to Markdown file
  # @return [Hash<String,String>] YAML by origin (for messages)
  def document_options(md)
    file = options_file(md)
    {"#{md} (comment)" => comment_options(md), file.to_s => (file.read if file.exist?)}.compact
  end

  # @param yaml   [String]   Options of a document: map of sections, each with pandoc defaults
  # @param origin [String]   Origin of the options, for messages
  # @param folder [Pathname] Folder of the Markdown file: value of `${.}`
  # @return [Hash<String,Hash>] Sections, with `${.}` replaced by the folder
  # @raise [RuntimeError] if not a map of known sections
  def parse_options(yaml, origin, folder)
    options = YAML.safe_load(yaml, permitted_classes: [Date, Time]) || {}
    raise "#{origin}: expected a map of sections: #{OPTION_SECTIONS.join(', ')}" unless options.is_a?(Hash)
    unknown = options.keys - OPTION_SECTIONS
    raise "#{origin}: unknown section: #{unknown.join(', ')}, expected: #{OPTION_SECTIONS.join(', ')}" unless unknown.empty?
    options.each do |section, defaults|
      raise "#{origin}: section #{section}: expected a map of pandoc defaults" unless defaults.nil? || defaults.is_a?(Hash)
    end
    expand_folder(options.compact, folder)
  rescue Psych::SyntaxError => e
    raise "#{origin}: #{e.message}"
  end

  # @param value  [Object]   YAML value
  # @param folder [Pathname] Folder
  # @return [Object] Value with `${.}` replaced by the folder in its strings, as pandoc does in a defaults file
  def expand_folder(value, folder)
    case value
    when Hash then value.transform_values { |item| expand_folder(item, folder) }
    when Array then value.map { |item| expand_folder(item, folder) }
    when String then value.gsub('${.}', folder.to_s)
    else value
    end
  end

  # Pandoc defaults files from the options of a document, one per section to apply
  # @param options  [Hash<String,Hash>] Sections, see #parse_options
  # @param sections [Array<String>]     Sections to apply, in order, e.g. `common`, `pdf`, `typst`
  # @param prefix   [Pathname]          Prefix of the generated files, e.g. in a temporary folder
  # @return [Array<Pathname>]
  def section_defaults(options, sections, prefix)
    sections.filter_map do |section|
      next unless options.key?(section)
      file = Pathname.new("#{prefix}.#{section}.yaml")
      file.write(YAML.dump(options[section]))
      file
    end
  end

  # Date of the last commit of the Markdown file, or its modification time if it has local changes or is not in git
  # @param md [Pathname] Path to Markdown file
  # @return [Time]
  def change_time(md)
    git = ['git', '-C', md.dirname]
    return md.mtime unless run(*git, 'status', '--porcelain', md.basename, capture: true).empty?
    date = run(*git, 'log', '-1', '--pretty=format:%cd', '--date=unix', md.basename, capture: true)
    date.empty? ? md.mtime : Time.at(date.to_i)
  rescue RuntimeError, SystemCallError
    md.mtime
  end

  # Convert HTML <img> to format expected in pandoc
  # @param content [String] HTML content to convert
  # @return [String] Converted content with Markdown image syntax
  def convert_img_for_pandoc(content)
    content.gsub(%r{<img\s+([^>]*?)/?>}) do
      attrs = Regexp.last_match(1)
      src = attrs[/src=["']([^"']*)["']/, 1]
      alt = attrs[/alt=["']([^"']*)["']/, 1] || ''
      "![#{alt}](#{src})"
    end
  end

  # Maximum number of HTTP redirections followed when downloading an image
  MAX_REDIRECTS = 5
  # File extension by media type, for a downloaded image whose URL has none
  IMAGE_EXTENSIONS = {'image/png' => '.png', 'image/jpeg' => '.jpg', 'image/gif' => '.gif', 'image/svg+xml' => '.svg', 'image/webp' => '.webp'}.freeze

  # Download a file by HTTP
  # @param url       [String]  URL
  # @param redirects [Integer] Remaining redirections to follow
  # @return [Array(String, String)] Content, and media type
  # @raise [RuntimeError] if the download fails
  def http_get(url, redirects = MAX_REDIRECTS)
    uri = URI.parse(url)
    response = Net::HTTP.get_response(uri)
    case response
    when Net::HTTPSuccess then [response.body, response['content-type'].to_s.split(';').first.to_s.strip.downcase]
    when Net::HTTPRedirection
      raise "Too many redirections: #{url}" if redirects.zero?
      http_get(URI.join(url, response['location']).to_s, redirects - 1)
    else raise "#{url}: HTTP #{response.code}"
    end
  rescue SystemCallError, SocketError, Timeout::Error, URI::InvalidURIError, OpenSSL::SSL::SSLError => e
    raise "#{url}: #{e.message}"
  end

  # Download the remote images of a Markdown text: PDF engines cannot always fetch them (Typst has no network access)
  # @param content [String]   Markdown text
  # @param folder  [Pathname] Folder where the images are saved
  # @return [String] Markdown text with the images `![alt](http...)` replaced by the downloaded files
  # @raise [RuntimeError] if a download fails
  def download_images(content, folder)
    files = {}
    content.gsub(%r{(!\[[^\]]*\]\()(https?://[^)\s]+)}) do
      prefix = Regexp.last_match(1)
      url = Regexp.last_match(2)
      files[url] ||= begin
        log.info { "Downloading: #{url}" }
        body, type = http_get(url)
        extension = File.extname(URI.parse(url).path)
        extension = IMAGE_EXTENSIONS.fetch(type, '') if extension.empty?
        folder.mkpath
        folder.join("#{Digest::SHA256.hexdigest(url)[0, 16]}#{extension}").tap { |file| file.binwrite(body) }
      end
      "#{prefix}#{files[url]}"
    end
  end

  # Font for characters missing in the main fonts, e.g. emoji
  # @return [String]
  def emoji_font
    RUBY_PLATFORM.include?('darwin') ? 'Apple Color Emoji' : 'Noto Color Emoji'
  end

  # Fonts of TeX Live for symbols missing in the main fonts and in the emoji font, e.g. `●`, by fallback variable of LaTeX
  SYMBOL_FONTS = {'mainfontfallback' => 'DejaVu Sans', 'monofontfallback' => 'DejaVu Sans Mono'}.freeze

  # Prepare the conversion of a Markdown file, and call the block in its folder (its relative paths are relative to it)
  # @param md       [Pathname] Path to Markdown file
  # @param output   [String]   `pdf` or `html`
  # @param engine   [String, nil] PDF engine
  # @param theme    [Pathname, nil] Theme folder
  # @yieldparam source   [Pathname]        Markdown file to give to pandoc
  # @yieldparam defaults [Array<Pathname>] Pandoc defaults files, in order
  # @yieldparam tmp      [Pathname]        Temporary folder
  def with_source(md, output, engine = nil, theme: nil)
    md = Pathname.new(md).expand_path
    Dir.mktmpdir('pandoc') do |tmp|
      tmp = Pathname.new(tmp)
      Dir.chdir(md.dirname) do
        source = tmp / md.basename
        content = convert_img_for_pandoc(md.read)
        # HTML references the remote images
        content = download_images(content, tmp / 'images') if output.eql?('pdf')
        source.write(content)
        target = engine || output
        # The options of the theme come before the ones of the document
        defaults = [ROOT / 'common/defaults.yaml', ROOT / target / 'defaults.yaml', theme_file(theme, "#{target}.yaml")].compact
        sections = ['common', output, engine].compact
        document_options(md).each_with_index do |(origin, yaml), index|
          defaults.concat(section_defaults(parse_options(yaml, origin, md.dirname), sections, tmp / "options#{index}"))
        end
        log.info { "Defaults: #{defaults.join(', ')}" }
        yield(source, defaults, tmp)
      end
    end
  end

  # Generate PDF from Markdown
  # @param md     [Pathname] Path to Markdown file
  # @param pdf    [Pathname] Path to output PDF file
  # @param engine [String]   PDF engine: `latex` or `typst`
  # @param theme  [String, Pathname, nil] Theme folder
  # @param mode   [String]   Mode of generation, see with_mode
  # @param inputs [Hash]     Extra `--input` key-value pairs for `typst compile` (Typst engine only), e.g. `{"product-name" => "IBM Aspera on Cloud"}`
  def markdown_to_pdf(md:, pdf:, engine: default_engine, theme: default_theme, mode: default_mode, inputs: {})
    raise ArgumentError, "Unknown PDF engine: #{engine}, expected one of: #{PDF_ENGINES.join(', ')}" unless PDF_ENGINES.include?(engine)
    theme = theme_folder(theme)
    md = Pathname.new(md).expand_path
    pdf = Pathname.new(pdf).expand_path
    with_mode(md, pdf, mode) do |mode_args|
      log.info { "Generating: #{pdf} with #{engine}#{", theme: #{theme}" if theme}, mode: #{mode}" }
      pdf.dirname.mkpath
      # after the fix of the Markdown file, if any
      time = change_time(md)
      with_source(md, 'pdf', engine, theme: theme) do |source, defaults, tmp|
        args = [*mode_args, "--variable=date:#{time.strftime('%Y/%m/%d')}", *defaults.map { |f| "--defaults=#{f}" }]
        if engine.eql?('latex')
          pdf_with_latex(source, pdf, args, tmp, theme, inputs: inputs)
        else
          pdf_with_typst(source, pdf, args, time, md, theme, inputs: inputs)
        end
      end
    end
  end

  # @param source [Pathname] Markdown file
  # @param pdf    [Pathname] Output PDF file
  # @param args   [Array<String>] Pandoc arguments
  # @param tmp    [Pathname] Temporary folder
  # @param theme  [Pathname, nil] Theme folder
  # @param inputs [Hash] Additional key-value pairs exposed to `cover.tex` as `\gfminput{key}` commands
  def pdf_with_latex(source, pdf, args, tmp, theme, inputs: {})
    # Folders of the images of LaTeX files, e.g. cover of the theme: https://latexref.xyz/_005cgraphicspath.html
    graphics_path = tmp / 'graphics_path.tex'
    graphics_path.write("\\usepackage{graphicx}\n\\graphicspath{#{[theme, '.'].compact.map { |dir| "{#{dir}/}" }.join}}\n")
    # Extra inputs exposed as \gfminput{key} in cover.tex, before the cover so it can use \gfminput
    headers = [graphics_path]
    unless inputs.empty?
      inputs_tex = tmp / 'inputs.tex'
      inputs_tex.write(inputs.map { |k, v| "\\newcommand{\\gfminput#{latex_csname(k)}}{#{v}}\n" }.join)
      headers << inputs_tex
    end
    # After the defaults: headers follow the order of the arguments, and the cover of the theme redefines a command of latex/pdf_in_header.tex
    headers << theme_file(theme, 'cover.tex')
    headers.compact!
    # Fonts of the platform or of TeX Live only: luaotfload fails on a missing fallback font.
    # In order: emoji, then symbols. Before the defaults: the variables of a theme or a document replace them.
    fallbacks = SYMBOL_FONTS.flat_map { |name, font| [emoji_font, font].map { |fallback| "--variable=#{name}:#{fallback}:mode=harf" } }
    run('pandoc', *fallbacks, *args, *headers.map { |f| "--include-in-header=#{f}" }, "--output=#{pdf}", source)
  ensure
    # Created by LaTeX package svg
    FileUtils.rm_rf('svg-inkscape')
  end

  # Convert an input key (e.g. "product-name") to a LaTeX command name suffix (e.g. "productname"):
  # keep only letters and digits (LaTeX command names cannot contain hyphens or other punctuation).
  def latex_csname(key)
    key.gsub(/[^a-zA-Z0-9]/, '')
  end

  # @param source [Pathname] Markdown file
  # @param pdf    [Pathname] Output PDF file
  # @param args   [Array<String>] Pandoc arguments
  # @param time   [Time] Creation date of the PDF, so that it changes only when the Markdown file changes
  # @param md     [Pathname] Original Markdown file
  # @param theme  [Pathname, nil] Theme folder
  # @param inputs [Hash] Additional `--input` key-value pairs passed to `typst compile`, e.g. `{"product-name" => "IBM Aspera on Cloud"}`
  def pdf_with_typst(source, pdf, args, time, md, theme, inputs: {})
    # Typst resolves image paths relative to the Typst file: it is next to the Markdown file
    typ = md.dirname / ".tmp.#{md.basename('.md')}.typ"
    run('pandoc', "--variable=template:#{ROOT / 'typst/report.typ'}", *args, "--output=#{typ}", source)
    # Inputs of the template, the cover of the theme is imported by it; caller may add extra inputs
    inputs = {'emoji-font' => emoji_font, 'cover' => theme_file(theme, 'cover.typ')}.merge(inputs).compact
    # Root `/`: the template, the theme and the images are in different folders
    command = ['typst', 'compile', '--root', '/', '--creation-timestamp', time.to_i, *inputs.flat_map { |name, value| ['--input', "#{name}=#{value}"] }, typ, pdf]
    return run(*command) unless args.include?('--fail-if-warnings')
    # Mode check: as for pandoc, a warning is an error, Typst has no option for it
    log.info { "Executing: #{command.join(' ')}" }
    _out, err, status = Open3.capture3(*command.map(&:to_s))
    $stderr.write(err)
    raise "typst: #{status.success? ? 'failing because there were warnings' : 'failed'}" unless status.success? && !err.match?(/^warning:/)
  ensure
    typ.delete if typ&.exist?
  end

  # Generate HTML from Markdown
  # @param md   [Pathname] Path to Markdown file
  # @param html [Pathname] Path to output HTML file
  # @param theme [String, Pathname, nil] Theme folder
  # @param mode  [String]   Mode of generation, see with_mode
  def markdown_to_html(md:, html:, theme: default_theme, mode: default_mode)
    theme = theme_folder(theme)
    md = Pathname.new(md).expand_path
    html = Pathname.new(html).expand_path
    with_mode(md, html, mode) do |mode_args|
      log.info { "Generating: #{html}, mode: #{mode}" }
      with_source(md, 'html', theme: theme) do |source, defaults, _tmp|
        run('pandoc', *mode_args, *defaults.map { |f| "--defaults=#{f}" }, "--output=#{html}", source)
      end
    end
  end

  # Collect heading identifiers and internal link targets (`#anchor`) of a Markdown file, as parsed by pandoc
  # @param md     [Pathname] Path to Markdown file
  # @param reader [String]   Pandoc input format, e.g. `gfm` or `markdown_mmd`
  # @return [Array(Set<String>, Array<String>)] heading identifiers, and internal link targets (without `#`)
  def pandoc_anchors(md, reader)
    ast = JSON.parse(run('pandoc', "--from=#{reader}", '--to=json', md, capture: true))
    ids = Set.new
    links = []
    walk = lambda do |node|
      case node
      when Array then node.each { |i| walk.call(i) }
      when Hash
        case node['t']
        when 'Header' then ids << node['c'][1][0]
        when 'Link' then links << node['c'][2][0].delete_prefix('#') if node['c'][2][0].start_with?('#')
        end
        node.each_value { |v| walk.call(v) }
      end
    end
    walk.call(ast['blocks'])
    [ids, links]
  end

  # Check that internal links (`#anchor`) of a Markdown file match a heading, both on GitHub and in the PDF.
  # GitHub and the pandoc reader used for PDF generate heading identifiers differently (e.g. `.` is kept by pandoc).
  # @param md [Pathname] Path to Markdown file
  # @raise [RuntimeError] if a link has no matching heading
  def check_markdown_anchors(md)
    pdf_reader = YAML.load_file(ROOT / 'common/defaults.yaml')['from']
    errors = ['gfm', pdf_reader].flat_map do |reader|
      ids, links = pandoc_anchors(md, reader)
      links.uniq.reject { |l| ids.include?(l) }.map { |l| "#{reader}: no heading for link: ##{l}" }
    end
    errors.each { |e| log.error(e) }
    raise "#{md}: #{errors.length} broken internal link(s)" unless errors.empty?
    log.info { "#{md}: internal links OK" }
  end

  # Figure numbers in the Markdown text, same rules as common/figure_caption.lua (test/pandoc_rb_test.rb runs both).
  # `Figure <number>`: not in a word (`Subfigure 1`), plain number (not `1.2`, `3a`), on one line or on two.
  # Groups: word `Figure` or `figure`, separator, number.
  FIGURE_NUMBER = /(?<![A-Za-z0-9])([Ff]igure)([ \t]+|[ \t]*\n[ \t>]*)(\d+)(?![A-Za-z0-9])(?!\.[A-Za-z0-9])/
  # After the number: figure of another document, e.g. `Figure 2 of RFC 1234`
  OTHER_DOCUMENT = /\G[ \t]+of(?=\s|\z)/
  # Start of a line, before an image: quote, indentation, list item
  LINE_START = '[ \t>]*(?:(?:[-*+]|\d+[.)])[ \t]+)?'
  # Image alone on its line: Markdown, or HTML (see convert_img_for_pandoc)
  IMAGE_LINE = /\A#{LINE_START}(?:!\[.*\]\(.*\)|<img\s[^>]*>)[ \t]*\z/
  # Before the number of a caption that is the alt text of an image
  ALT_CAPTION_PREFIX = /\A#{LINE_START}!\[\z/
  # Before the number of a manual caption: quote, indentation, emphasis
  CAPTION_PREFIX = /\A[ \t>]*[*_]*\z/

  # Numbers of the figures of a Markdown file, as parsed by pandoc with the filters of the toolchain
  # @param md [Pathname] Path to Markdown file
  # @return [Array<Integer>] Plain numbers of the captions `Figure <number>`, in the order of the document
  def pandoc_figure_numbers(md)
    md = Pathname.new(md).expand_path
    ast = Dir.mktmpdir('pandoc') do |tmp|
      source = Pathname.new(tmp) / md.basename
      source.write(convert_img_for_pandoc(md.read))
      Dir.chdir(md.dirname) { JSON.parse(run('pandoc', "--defaults=#{ROOT / 'common/defaults.yaml'}", '--to=json', source, capture: true)) }
    end
    text = lambda do |node|
      case node
      when Array then node.map { |n| text.call(n) }.join
      when Hash
        case node['t']
        when 'Str' then node['c']
        when 'Space', 'SoftBreak', 'LineBreak' then ' '
        else text.call(node['c'])
        end
      else ''
      end
    end
    numbers = []
    walk = lambda do |node|
      case node
      when Array then node.each { |n| walk.call(n) }
      when Hash
        number = text.call(node['c'][1][1])[/\AFigure\s+(\d+)(?![A-Za-z0-9])(?!\.[A-Za-z0-9])/, 1] if node['t'].eql?('Figure')
        numbers << number.to_i if number
        node.each_value { |v| walk.call(v) }
      end
    end
    walk.call(ast['blocks'])
    numbers
  end

  # Ranges of a Markdown text where figures are not numbered: code blocks, inline code, HTML comments
  # @param text [String] Markdown text
  # @return [Array<Range>] Character offsets
  def figure_free_ranges(text)
    ranges = []
    offset = 0
    fence = nil
    text.each_line do |line|
      marker = line.sub(/\A[ \t>]*/, '')
      if fence
        ranges << (offset...offset + line.length)
        fence = nil if marker.match?(/\A#{Regexp.escape(fence[0])}{#{fence.length},}[ \t]*$/)
      elsif (fence = marker[/\A(?:`{3,}|~{3,})/])
        ranges << (offset...offset + line.length)
      end
      offset += line.length
    end
    # HTML comments, inline code: on several lines, but not across an empty line (not a stray backtick)
    [/<!--.*?-->/m, /(?<!`)(`+)(?!`)(?:[^\n]|\n(?![ \t>]*\n))+?(?<!`)\1(?!`)/].each do |pattern|
      text.to_enum(:scan, pattern).each { ranges << (Regexp.last_match.begin(0)...Regexp.last_match.end(0)) }
    end
    ranges
  end

  # @param text  [String]      Markdown text
  # @param match [MatchData]   Match of FIGURE_NUMBER
  # @return [Boolean] true if the match is the number of a caption: the alt text of an image alone on its line, or a
  #   paragraph after it (or its next line), see common/figure_caption.lua
  def figure_caption?(text, match)
    return false unless match[1].eql?('Figure')
    start = match.begin(0)
    line_start = start.zero? ? 0 : (text.rindex("\n", start - 1)&.+(1) || 0)
    prefix = text[line_start...start]
    return text[line_start...(text.index("\n", start) || text.length)].match?(IMAGE_LINE) if prefix.match?(ALT_CAPTION_PREFIX)
    return false unless prefix.match?(CAPTION_PREFIX)
    previous = text[0...line_start].lines.map(&:chomp).last(2)
    # an empty line between the image and the caption, in a quote or not
    previous.pop if previous.last&.match?(/\A[ \t>]*\z/)
    previous.last&.match?(IMAGE_LINE) || false
  end

  # Renumber the figures of a Markdown file: captions 1, 2, 3... in the order of the document, and the mentions
  # `Figure <number>` in the text follow their figure. Not in code and HTML comments, not `Figure 2 of RFC 1234`.
  # To add a figure, give it a number not used yet, e.g. `Figure 0`, mention it so, then renumber.
  # @param md [Pathname] Path to Markdown file, rewritten if a number changes
  # @return [Array(Array<String>, Array<String>)] Changes, and mentions not renumbered: `<file>:<line>: <message>`
  # @raise [RuntimeError] if the captions found in the text are not the figures of pandoc, or if a mention not
  #   renumbered would refer to another figure: the file is not changed
  def renumber_figures(md)
    md = Pathname.new(md)
    text = md.read
    numbers = pandoc_figure_numbers(md)
    free = figure_free_ranges(text)
    matches = text.to_enum(:scan, FIGURE_NUMBER).map { Regexp.last_match }.reject { |m| free.any? { |r| r.cover?(m.begin(0)) } }
    captions, mentions = matches.partition { |m| figure_caption?(text, m) }
    found = captions.map { |m| m[3].to_i }
    raise "#{md}: figures of pandoc (#{numbers.join(', ')}) not found in the text (#{found.join(', ')}), renumber them by hand" unless found.eql?(numbers)
    counts = numbers.tally
    renumber = numbers.each_with_index.to_h { |old, index| [old, index + 1] }.select { |old, _| counts[old].eql?(1) }
    where = ->(m) { "#{md}:#{text[0, m.begin(3)].count("\n") + 1}" }
    skipped = []
    targets = captions.each_with_index.map { |m, index| [m, index + 1] }
    mentions.each do |m|
      next if text.match?(OTHER_DOCUMENT, m.end(0))
      old = m[3].to_i
      next targets << [m, renumber[old]] if renumber[old]
      skipped << [m, old]
    end
    # A mention not renumbered keeps its number: it must not become the one of another figure, e.g. caption `Figure 2`
    # of code (not a figure), between figures 1 and 3 that become 1 and 2
    taken = skipped.select { |_, old| old.between?(1, numbers.length) && !numbers[old - 1].eql?(old) }
    unless taken.empty?
      list = taken.map { |m, old| "line #{where.call(m)[/\d+\z/]}: Figure #{old}" }.join(', ')
      raise "#{md}: not changed, mentions that would refer to another figure: #{list}. Change them by hand (e.g. `Listing` for a caption of code), then renumber"
    end
    skipped = skipped.map { |m, old| "#{where.call(m)}: Figure #{old} not renumbered: #{counts[old] ? 'several figures have this number' : 'no figure has this number'}" }
    targets = targets.reject { |m, new| m[3].to_i.eql?(new) }.sort_by { |m, _| m.begin(3) }
    changes = targets.map { |m, new| "#{where.call(m)}: Figure #{m[3]} -> Figure #{new}" }
    targets.reverse_each { |m, new| text[m.begin(3)...m.end(3)] = new.to_s }
    md.write(text) unless targets.empty?
    changes.each { |c| log.info(c) }
    skipped.each { |s| log.warn(s) }
    log.info { "#{md}: figures already numbered" } if targets.empty?
    [changes, skipped]
  end

  # Check that the version of the toolchain meets the requirement of a project
  # @param requirement [String] RubyGems syntax, e.g. `~> 1.0`, or a range: `>= 1.1, < 3`
  # @raise [RuntimeError] if the version does not meet it
  # @raise [ArgumentError] if the requirement is not valid
  def check_version(requirement)
    return if Gem::Requirement.new(*requirement.split(',').map(&:strip)).satisfied_by?(Gem::Version.new(VERSION))
    raise "gfm2pdf-toolchain #{VERSION} (#{ROOT}) does not meet the required version: #{requirement}"
  end
end

if __FILE__ == $PROGRAM_NAME
  usage = <<~TEXT
    Usage: #{File.basename($PROGRAM_NAME)} <command> [arguments]

    Commands:
      deps                           list the files the generated documents depend on, for make
      pdf <input.md> <output.pdf>    convert Markdown to PDF, engine from env var GFM2PDF_ENGINE: latex (default) or typst
      html <input.md> <output.html>  convert Markdown to HTML
      check-anchors <input.md>       check that internal links match a heading, on GitHub and in the PDF
      renumber-figures <input.md>    renumber the figures 1, 2, 3... and their mentions `Figure <number>`, in place
      version [<requirement>]        display the version, check that it meets the requirement, e.g. '~> 1.0'

    Env var GFM2PDF_THEME: theme folder (cover, fonts, ...) for deps, pdf and html, see README.md
    Env var GFM2PDF_MODE for pdf and html: build (default), check (a warning is an error, no output) or fix (renumber
    the figures of the Markdown file, then build)
  TEXT
  command, *args = ARGV
  begin
    case command
    when 'version'
      abort(usage) if args.length > 1
      Gfm2Pdf.check_version(args.first) unless args.empty?
      puts(Gfm2Pdf::VERSION)
    when 'deps' then args.empty? ? puts(Gfm2Pdf.dependencies.join(' ')) : abort(usage)
    when 'pdf' then args.length.eql?(2) ? Gfm2Pdf.markdown_to_pdf(md: args[0], pdf: args[1]) : abort(usage)
    when 'html' then args.length.eql?(2) ? Gfm2Pdf.markdown_to_html(md: args[0], html: args[1]) : abort(usage)
    when 'check-anchors' then args.length.eql?(1) ? Gfm2Pdf.check_markdown_anchors(Pathname.new(args[0])) : abort(usage)
    when 'renumber-figures' then args.length.eql?(1) ? Gfm2Pdf.renumber_figures(args[0]) : abort(usage)
    else abort(usage)
    end
  rescue StandardError => e
    warn(e.backtrace.join("\n")) if ENV['DEBUG']
    abort("Error: #{e.message}")
  end
end
