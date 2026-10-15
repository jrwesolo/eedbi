# frozen_string_literal: true

require 'rake/testtask'

LAYERS = %w[unit cli system compat].freeze

desc 'Run all tests'
Rake::TestTask.new(:test) do |t|
  t.libs << 'test'
  t.pattern = 'test/{unit,cli,system,compat}/**/*_test.rb'
  t.warning = true
end

namespace :test do
  LAYERS.each do |layer|
    desc "Run the #{layer} tests"
    Rake::TestTask.new(layer) do |t|
      t.libs << 'test'
      t.pattern = "test/#{layer}/**/*_test.rb"
      t.warning = true
    end
  end
end

desc 'Build the gem into pkg/'
task :build do
  FileUtils.mkdir_p('pkg')
  sh 'gem build eedbi.gemspec --output pkg/eedbi.gem'
end

begin
  require 'rubocop/rake_task'
  RuboCop::RakeTask.new
  task default: %i[rubocop test]
rescue LoadError
  task default: :test
end
