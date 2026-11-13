Gem::Specification.new do |spec|
  spec.name = 'expect4r-routers'
  spec.version = '2.0.0'
  spec.authors = ['Jean-Michel Esnault']
  spec.email = 'jesnault@gmail.com'
  spec.summary = 'Router automation using the expect4r dialogue engine'
  spec.homepage = 'https://github.com/jeanmichel-gh/expect4r'
  spec.license = 'Nonstandard'
  spec.required_ruby_version = '>= 4.0.6'
  spec.files = Dir.chdir(__dir__) { Dir['lib/**/*.rb', 'README.md', 'LICENSE', 'COPYING'] }
  spec.require_paths = ['lib']
  spec.add_dependency 'expect4r', '~> 2.0'
end
