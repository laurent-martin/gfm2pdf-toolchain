# frozen_string_literal: true

require 'rake/testtask'

# Tests needing a missing tool (typst, lualatex, pdftotext, make) are skipped
Rake::TestTask.new(:test) do |t|
  t.test_files = FileList['test/*_test.rb']
  t.warning = true
end

task default: :test
