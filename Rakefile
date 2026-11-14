require 'rake/clean'
require 'rake/testtask'
require 'rdoc/task'
require 'rubygems'

CLEAN.include('*.gem', 'pkg', 'rdoc')
Rake::TestTask.new(:core) do |task|
  task.libs = ['lib', '.']
  task.pattern = 'test/core/**/*test.rb'
  task.warning = true
end
RDoc::Task.new do |task|
  task.rdoc_dir = 'rdoc'
  task.rdoc_files.include('README.md', 'lib/**/*.rb')
  task.options = ['--quiet', '--title', 'Expect4r', '--line-numbers']
end
desc 'Build the core gem directly from current source'
task :package do
  spec = Gem::Specification.load('expect4r.gemspec')
  mkdir_p 'pkg'
  ruby '-S', 'gem', 'build', 'expect4r.gemspec', '--output', "pkg/#{spec.full_name}.gem"
end
task gem: :package
Rake::TestTask.new(:legacy) do |task|
  task.warning = false
  task.libs = ['legacy/lib', '.']
  task.pattern = 'legacy/test/**/*test.rb'
end
Rake::TestTask.new(:routers) do |task|
  task.libs = ['lib', 'applications/routers/lib', '.']
  task.pattern = 'applications/routers/test/**/*test.rb'
  task.warning = true
end
task test: [:core, :routers, :legacy]
desc 'Build the companion router gem'
task :package_routers do
  Dir.chdir('applications/routers') do
    spec = Gem::Specification.load('expect4r-routers.gemspec')
    ruby '-S', 'gem', 'build', 'expect4r-routers.gemspec', '--output', "../../pkg/#{spec.full_name}.gem"
  end
end
task package_routers: :package
task default: :test
