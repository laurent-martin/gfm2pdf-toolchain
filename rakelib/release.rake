# frozen_string_literal: true

# Release of the toolchain: version in file VERSION, changes in CHANGELOG.md, tag vX.Y.Z, see README.md

require 'date'
require 'tmpdir'
require_relative '../lib/pandoc'

namespace :release do
  # Suffix of the version between releases
  PRE_SUFFIX = '.pre'
  # Release date of the version in development, in CHANGELOG.md
  DATE_PLACE_HOLDER = 'Released: [Place date of release here]'
  VERSION_FILE = Gfm2Pdf::ROOT / 'VERSION'
  CHANGELOG_FILE = Gfm2Pdf::ROOT / 'CHANGELOG.md'
  # Format of a release version
  RELEASE_FORMAT = /\A\d+\.\d+\.\d+\z/

  private

  # If env var `DRY_RUN` is `1`, the `git` and `gh` commands that change something are displayed, not executed
  def dry_run?
    ENV['DRY_RUN'] == '1'
  end

  # Execute a command that changes something, unless dry run
  # @param cmd [Array] Command and arguments
  def drun(*cmd)
    if dry_run?
      Gfm2Pdf.log.info { "Would execute: #{cmd.join(' ')}" }
    else
      Gfm2Pdf.run(*cmd)
    end
  end

  # Versions of a release
  # @param release_version [String, nil] Release version, default: the version in VERSION without `.pre`
  # @param next_version    [String, nil] Next version, default: next minor version
  # @return [Hash<Symbol,String>] :current, :release, :tag, :next_dev
  def release_versions(release_version, next_version)
    current = VERSION_FILE.read.strip
    release = release_version.to_s.empty? ? current.delete_suffix(PRE_SUFFIX) : release_version
    if next_version.to_s.empty?
      major, minor, = release.split('.').map(&:to_i)
      next_version = [major, minor + 1, 0].join('.')
    end
    [release, next_version].each { |version| raise "Version must be x.y.z: #{version}" unless RELEASE_FORMAT.match?(version) }
    {current: current, release: release, tag: "v#{release}", next_dev: "#{next_version}#{PRE_SUFFIX}"}
  end

  # @param content [String] Content of CHANGELOG.md
  # @param version [String] Version
  # @return [String] Section of the version, with its heading
  def changelog_section(content, version)
    match = content.match(/^## #{Regexp.escape(version)}\n.*?(?=^## |\z)/m)
    raise "Missing section `## #{version}` in #{CHANGELOG_FILE}" if match.nil?
    match[0]
  end

  # CHANGELOG.md for the release: version and date in the section of the version in development, empty
  # subsections removed
  # @param current [String] Version in development, with `.pre`
  # @param release [String] Release version
  def update_changelog_for_release(current, release)
    content = CHANGELOG_FILE.read
    section = changelog_section(content, current)
    raise "Missing `#{DATE_PLACE_HOLDER}` in section #{current} of #{CHANGELOG_FILE}" unless section.include?(DATE_PLACE_HOLDER)
    released = section
      .sub("## #{current}\n") { "## #{release}\n" }
      .sub(DATE_PLACE_HOLDER) { "Released: #{Date.today.strftime('%Y-%m-%d')}" }
      .gsub(/^### .+\n+(?=^##|\z)/, '')
    CHANGELOG_FILE.write(content.sub(section) { released })
  end

  # Add the section of the next version in development at the top of CHANGELOG.md
  # @param next_dev [String] Next version, with `.pre`
  def add_next_changelog_section(next_dev)
    section = "## #{next_dev}\n\n#{DATE_PLACE_HOLDER}\n\n### New\n\n### Changed\n\n### Fixed\n\n"
    CHANGELOG_FILE.write(CHANGELOG_FILE.read.sub(/^## /) { "#{section}## " })
  end

  # @param version [String] Version
  # @return [String] Release notes: section of the version in CHANGELOG.md without its heading and date, subsections at
  #   level 2
  def release_notes(version)
    changelog_section(CHANGELOG_FILE.read, version).sub(/\A## .+\n+(Released: .+\n+)?/, '').strip.gsub(/^### /, '## ')
  end

  # @return [Boolean] true if the repository has the remote `origin`
  def origin?
    system('git', 'remote', 'get-url', 'origin', out: File::NULL, err: File::NULL)
  end

  # @param tag [String] Tag name
  # @return [Boolean] true if the tag exists
  def tag?(tag)
    system('git', 'rev-parse', '--quiet', '--verify', "refs/tags/#{tag}", out: File::NULL)
  end

  # Check that `gh` can access the repository of the remote `origin`, unless dry run.
  # Not `gh api user`: the token of a GitHub Actions workflow has no access to the user.
  def check_github_access
    Gfm2Pdf.run('gh', 'repo', 'view', '--json', 'name', capture: true) unless dry_run?
  end

  # Push the branch `main` and the tag, and create the GitHub release with the changes of the version
  # @param version [String] Release version
  def publish_release(version)
    tag = "v#{version}"
    Dir.mktmpdir('release') do |tmp|
      notes = Pathname.new(tmp) / 'release_notes.md'
      notes.write(release_notes(version))
      Gfm2Pdf.log.info { "Release notes:\n#{notes.read}" }
      drun('git', 'push', 'origin', 'main', tag)
      drun('gh', 'release', 'create', tag, '--verify-tag', '--title', "gfm2pdf-toolchain #{tag}", '--notes-file', notes)
    end
  end

  desc 'Release: commit and tag, publish if remote origin, args: release_version (default: VERSION without .pre), next_version (default: next minor)'
  task :run, %i[release_version next_version] do |_t, args|
    versions = release_versions(args[:release_version], args[:next_version])
    Gfm2Pdf.log.info { "Release #{versions[:release]}, then #{versions[:next_dev]}" }
    raise "Version in #{VERSION_FILE} must end with #{PRE_SUFFIX}: #{versions[:current]}" unless versions[:current].end_with?(PRE_SUFFIX)
    raise 'Release from branch main only' unless Gfm2Pdf.run('git', 'branch', '--show-current', capture: true).strip.eql?('main')
    status = Gfm2Pdf.run('git', 'status', '--porcelain', capture: true)
    raise "Changes not committed:\n#{status}" unless status.empty?
    raise "Tag already exists: #{versions[:tag]}" if tag?(versions[:tag])
    publish = origin?
    check_github_access if publish
    Rake::Task['test'].invoke
    # Release
    VERSION_FILE.write("#{versions[:release]}\n")
    update_changelog_for_release(versions[:current], versions[:release])
    drun('git', 'add', '-A')
    drun('git', 'commit', '-m', "Release #{versions[:tag]}")
    drun('git', 'tag', '-a', versions[:tag], '-m', "Version #{versions[:release]}")
    if publish
      publish_release(versions[:release])
    else
      Gfm2Pdf.log.warn { "No remote origin, publish later with: rake release:publish[#{versions[:release]}]" }
    end
    # Next development cycle
    VERSION_FILE.write("#{versions[:next_dev]}\n")
    add_next_changelog_section(versions[:next_dev])
    drun('git', 'add', '-A')
    drun('git', 'commit', '-m', "Prepare for next development cycle (#{versions[:next_dev]})")
    drun('git', 'push', 'origin', 'main') if publish
    Gfm2Pdf.log.info { "Release #{versions[:release]} completed" }
  end

  desc 'Publish a release made without remote: push, and GitHub release, arg: version'
  task :publish, [:version] do |_t, args|
    version = args[:version].to_s
    raise "Version must be x.y.z: #{version}" unless RELEASE_FORMAT.match?(version)
    raise "Missing tag: v#{version}" unless tag?("v#{version}")
    raise 'Missing remote origin' unless origin?
    check_github_access
    publish_release(version)
  end
end
