require 'yaml'

Gem::Specification.new do |spec|
  version = YAML.safe_load(File.read(File.join(__dir__, 'VERSION.yml')), permitted_classes: [Symbol])
  spec.name = 'expect4r'
  spec.version = [:major, :minor, :patch].map { |part| version.fetch(part) }.join('.')
  spec.authors = ['Jean-Michel Esnault']
  spec.email = 'jesnault@gmail.com'
  spec.summary = 'Script terminal dialogues in Ruby with Expect-style patterns'
  spec.description = 'A PTY dialogue engine with ordered pattern/action blocks, explicit deadlines and bounded buffers.'
  spec.homepage = 'https://github.com/jeanmichel-gh/expect4r'
  spec.license = 'Nonstandard' # See the existing LICENSE and COPYING; terms are unchanged.
  spec.files = Dir.chdir(__dir__) { %w[LICENSE COPYING README.md CHANGELOG VERSION.yml ASSESSMENT.md] + Dir['lib/**/*.rb', 'docs/*', 'examples/*.rb'] }
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 4.0.6'
  spec.add_dependency 'expect-pty', '= 0.10.1'
end
