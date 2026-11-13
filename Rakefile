require 'rake/clean'
require 'rake/testtask'
require 'rdoc/task'
require 'rubygems/package_task'

CLEAN.include('*.gem', 'pkg', 'rdoc')
Rake::TestTask.new do |task|
  task.libs = ['lib', '.']
  task.pattern = 'test/{core,router}/**/*test.rb'
  task.warning = true
end
RDoc::Task.new do |task|
  task.rdoc_dir = 'rdoc'
  task.rdoc_files.include('README.md', 'lib/**/*.rb')
  task.options = ['--quiet', '--title', 'Expect4r', '--line-numbers']
end
Gem::PackageTask.new(Gem::Specification.load('expect4r.gemspec')).define
Rake::TestTask.new(:legacy) do |task|
  task.warning = false
  task.libs = ['lib', '.']
  task.pattern = 'test/legacy/**/*test.rb'
end
task test: :legacy
task default: :test
