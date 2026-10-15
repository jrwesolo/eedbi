# frozen_string_literal: true

require_relative 'lib/eedbi/version'

Gem::Specification.new do |spec|
  spec.name = 'eedbi'
  spec.version = Eedbi::VERSION
  spec.authors = ['Jordan Wesolowski']
  spec.summary = 'Edit Chef encrypted data bag items without Chef'
  spec.description = 'Create, edit, check, migrate and rekey Chef encrypted data bag items ' \
                     '(format versions 0 to 3) with only the Ruby standard library.'
  spec.homepage = 'https://github.com/jrwesolo/eedbi'
  spec.license = 'MIT'
  # Keep in step with TargetRubyVersion in .rubocop.yml, min_version in
  # .github/workflows/pipeline.yml and the check in bin/eedbi. 3.1 is the
  # Ruby in Chef and Cinc 18.
  spec.required_ruby_version = '>= 3.1'

  spec.files = Dir['lib/**/*.rb', 'bin/eedbi', 'README.md', 'LICENSE.md', 'CHANGELOG.md']
  spec.bindir = 'bin'
  spec.executables = ['eedbi']

  spec.metadata = {
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'rubygems_mfa_required' => 'true'
  }
end
