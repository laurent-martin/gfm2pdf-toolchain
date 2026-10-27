#!/usr/bin/env ruby
# frozen_string_literal: true

# Generate PDF (with Typst or LuaLaTeX) or HTML from Markdown using pandoc, see README.md

require 'date'
require 'fileutils'
require 'json'
require 'logger'
require 'open3'
require 'pathname'
require 'set'
require 'tmpdir'
require 'yaml'

module Gfm2Pdf
  # Root folder of the toolchain
  ROOT = Pathname.new(__dir__).parent.freeze
  # Version of the toolchain: `x.y.z` for a release, `x.y.z.pre` between releases, see README.md
  VERSION = ROOT.join('VERSION').read.strip.freeze
  # PDF engines, the first one is the default
  PDF_ENGINES = %w[latex typst].freeze
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

  # Font for characters missing in the main fonts, e.g. emoji
  # @return [String]
  def emoji_font
    RUBY_PLATFORM.include?('darwin') ? 'Apple Color Emoji' : 'Noto Color Emoji'
  end

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
        source.write(convert_img_for_pandoc(md.read))
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
  def markdown_to_pdf(md:, pdf:, engine: default_engine, theme: default_theme)
    raise ArgumentError, "Unknown PDF engine: #{engine}, expected one of: #{PDF_ENGINES.join(', ')}" unless PDF_ENGINES.include?(engine)
    theme = theme_folder(theme)
    md = Pathname.new(md).expand_path
    pdf = Pathname.new(pdf).expand_path
    log.info { "Generating: #{pdf} with #{engine}#{", theme: #{theme}" if theme}" }
    pdf.dirname.mkpath
    time = change_time(md)
    with_source(md, 'pdf', engine, theme: theme) do |source, defaults, tmp|
      args = ["--variable=date:#{time.strftime('%Y/%m/%d')}", *defaults.map { |f| "--defaults=#{f}" }]
      if engine.eql?('latex')
        pdf_with_latex(source, pdf, args, tmp, theme)
      else
        pdf_with_typst(source, pdf, args, time, md, theme)
      end
    end
  end

  # @param source [Pathname] Markdown file
  # @param pdf    [Pathname] Output PDF file
  # @param args   [Array<String>] Pandoc arguments
  # @param tmp    [Pathname] Temporary folder
  # @param theme  [Pathname, nil] Theme folder
  def pdf_with_latex(source, pdf, args, tmp, theme)
    # Folders of the images of LaTeX files, e.g. cover of the theme: https://latexref.xyz/_005cgraphicspath.html
    graphics_path = tmp / 'graphics_path.tex'
    graphics_path.write("\\usepackage{graphicx}\n\\graphicspath{#{[theme, '.'].compact.map { |dir| "{#{dir}/}" }.join}}\n")
    # After the defaults: headers follow the order of the arguments, and the cover of the theme redefines a command of latex/pdf_in_header.tex
    headers = [graphics_path, theme_file(theme, 'cover.tex')].compact
    # Only the font of the platform: luaotfload fails on a missing fallback font.
    # Before the defaults: the variables of a theme or a document replace them.
    fallbacks = %w[mainfontfallback monofontfallback].map { |name| "--variable=#{name}:#{emoji_font}:mode=harf" }
    run('pandoc', *fallbacks, *args, *headers.map { |f| "--include-in-header=#{f}" }, "--output=#{pdf}", source)
  ensure
    # Created by LaTeX package svg
    FileUtils.rm_rf('svg-inkscape')
  end

  # @param source [Pathname] Markdown file
  # @param pdf    [Pathname] Output PDF file
  # @param args   [Array<String>] Pandoc arguments
  # @param time   [Time] Creation date of the PDF, so that it changes only when the Markdown file changes
  # @param md     [Pathname] Original Markdown file
  # @param theme  [Pathname, nil] Theme folder
  def pdf_with_typst(source, pdf, args, time, md, theme)
    # Typst resolves image paths relative to the Typst file: it is next to the Markdown file
    typ = md.dirname / ".tmp.#{md.basename('.md')}.typ"
    run('pandoc', "--variable=template:#{ROOT / 'typst/report.typ'}", *args, "--output=#{typ}", source)
    # Inputs of the template, the cover of the theme is imported by it
    inputs = {'emoji-font' => emoji_font, 'cover' => theme_file(theme, 'cover.typ')}.compact
    # Root `/`: the template, the theme and the images are in different folders
    run('typst', 'compile', '--root', '/', '--creation-timestamp', time.to_i, *inputs.flat_map { |name, value| ['--input', "#{name}=#{value}"] }, typ, pdf)
  ensure
    typ.delete if typ&.exist?
  end

  # Generate HTML from Markdown
  # @param md   [Pathname] Path to Markdown file
  # @param html [Pathname] Path to output HTML file
  # @param theme [String, Pathname, nil] Theme folder
  def markdown_to_html(md:, html:, theme: default_theme)
    theme = theme_folder(theme)
    html = Pathname.new(html).expand_path
    log.info { "Generating: #{html}" }
    with_source(md, 'html', theme: theme) do |source, defaults, _tmp|
      run('pandoc', *defaults.map { |f| "--defaults=#{f}" }, "--output=#{html}", source)
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
      version [<requirement>]        display the version, check that it meets the requirement, e.g. '~> 1.0'

    Env var GFM2PDF_THEME: theme folder (cover, fonts, ...) for deps, pdf and html, see README.md
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
    else abort(usage)
    end
  rescue StandardError => e
    warn(e.backtrace.join("\n")) if ENV['DEBUG']
    abort("Error: #{e.message}")
  end
end
