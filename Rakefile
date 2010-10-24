require 'rake'
require 'rake/rdoctask'
require 'rake/testtask'
require "rake/clean"

task "default" => 'test'

CLEAN.include ["*.gem", "pkg", "rdoc"]

begin
  require 'jeweler'
  Jeweler::Tasks.new do |s|
    s.name = 'expect4r'
    s.authors = ['Jean-Michel Esnault']
    s.email = "jesnault@gmail.com"
    s.summary = "Expect4r"
    s.description = "A Ruby Library for interacting with Ios, IosXR, and Junos CLI."
    s.platform = Gem::Platform::RUBY
    s.executables = []
    s.files = %w( LICENSE COPYING README.rdoc ) + Dir["lib/**/*"] + ["examples/**/*"]
    s.test_files = Dir["test/**/*"]
    s.has_rdoc = false
    s.rdoc_options = ["--quiet", "--title", "Expect4r", "--line-numbers"]
    s.require_path = 'lib'
    s.required_ruby_version = ">= 1.8.7"
    s.add_dependency('highline', '>= 1.5.0')
    # s.homepage = "http://github.com/jesnault"
    # s.rubyforge_project = 'expect4'
  end
rescue LoadError
  puts "Jeweler not available. Install it with: sudo gem install jeweler"
end

# These are new tasks
begin
  require 'rake/contrib/sshpublisher'
  namespace :rubyforge do

    desc "Release gem and RDoc documentation to RubyForge"
    task :release => ["rubyforge:release:gem", "rubyforge:release:docs"]

    namespace :release do
      desc "Publish RDoc to RubyForge."
      task :docs => [:rdoc] do
        config = YAML.load(
            File.read(File.expand_path('~/.rubyforge/user-config.yml'))
        )
        host = "#{config['username']}@rubyforge.org"
        remote_dir = "/var/www/gforge-projects/the-perfect-gem/"
        local_dir = 'rdoc'

        Rake::SshDirPublisher.new(host, remote_dir, local_dir).upload
      end
    end
  end
rescue LoadError
  puts "Rake SshDirPublisher is unavailable or your rubyforge environment is not configured."
end


Rake::TestTask.new do |t|
  t.libs = ['.']
  t.pattern = "test/**/*test.rb"
  t.warning = true
end

Rake::RDocTask.new do |t|
  t.rdoc_dir = 'rdoc'
  t.rdoc_files.include("lib/**/*.rb")
  t.options =  ["--quiet", "--title", "Expect4r", "--line-numbers"] 
  t.options << '--fileboxes'
end

require 'rake/gempackagetask'

namespace :gem do

  desc "Run :package and install the .gem locally"
  task :install => [:gem, :package] do
    sh %{sudo gem install --local pkg/interact-#{PKG_VERSION}.gem}
  end

  desc "Like gem:install but without ri or rdocs"
  task :install_fast => [:gem, :package] do
    sh %{sudo gem install --local pkg/interact-#{PKG_VERSION}.gem --no-rdoc --no-ri}
  end

  desc "Run :clean and uninstall the .gem"
  task :uninstall => :clean do
    sh %{sudo gem uninstall interact}
  end

end
