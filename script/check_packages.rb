# frozen_string_literal: true
# Run after `rake package_routers`. Installs into a disposable, isolated gem home.
require 'tmpdir'
require 'open3'
require 'rbconfig'
require 'rubygems/package'

root = File.expand_path('..', __dir__)
core = File.join(root, 'pkg/expect4r-2.0.0.gem')
routers = File.join(root, 'pkg/expect4r-routers-2.0.0.gem')
dependencies = []
collect = lambda do |spec|
  next if spec.default_gem? || dependencies.any? { |entry| entry.name == spec.name }
  dependencies << spec
  spec.runtime_dependencies.each { |dep| collect.call(Gem::Specification.find_by_name(dep.name, dep.requirement)) }
end
collect.call(Gem::Specification.find_by_name('expect-pty', '= 0.10.1'))
dependencies.each do |spec|
  raise "Missing cached dependency: #{spec.cache_file}" unless File.file?(spec.cache_file)
end
core_spec = Gem::Package.new(core).spec
raise 'Core contains application/legacy code' if core_spec.files.any? { |f| f.match?(%r{\A(?:applications|legacy|lib/(?:router|misc|expect)/)|expect4r/(?:router|legacy)}) }
raise 'Unexpected core runtime dependencies' unless core_spec.runtime_dependencies.map(&:name) == ['expect-pty']
router_spec = Gem::Package.new(routers).spec
raise 'Unexpected application dependencies' unless router_spec.runtime_dependencies.map(&:name) == ['expect4r']

Dir.mktmpdir('expect4r-packages-') do |home|
  [[core, root, 'expect4r.gemspec'],
   [routers, File.join(root, 'applications/routers'), 'expect4r-routers.gemspec']].each_with_index do |(path, source, gemspec), index|
    package = Gem::Package.new(path)
    expected = Gem::Specification.load(File.join(source, gemspec))
    raise "Stale package file list: #{path}" unless package.spec.files.sort == expected.files.sort
    extracted = File.join(home, "source-check-#{index}")
    package.extract_files(extracted)
    expected.files.each do |file|
      unless File.binread(File.join(source, file)) == File.binread(File.join(extracted, file))
        raise "Stale packaged source: #{file}"
      end
    end
  end
  puts 'Both gem payloads match current source'
  env = ENV.keys.grep(/\ABUNDLE_/).to_h { |key| [key, nil] }
  env.merge!('GEM_HOME' => home, 'GEM_PATH' => home, 'RUBYOPT' => nil, 'RUBYLIB' => nil)
  run = lambda do |*args|
    output, status = Open3.capture2e(env, RbConfig.ruby, *args, chdir: home)
    raise output unless status.success?
    puts output unless output.empty?
  end
  install = lambda do |path|
    run.call('-rrubygems/gem_runner', '-e', 'Gem::GemRunner.new.run(ARGV)', '--',
             'install', '--local', '--no-document', '--ignore-dependencies', path)
  end
  dependencies.reverse_each { |spec| install.call(spec.cache_file) }
  install.call(core)
  run.call('-e', <<~'CODE')
    require 'expect4r'
    raise 'Router constant in core' if Expect4r.const_defined?(:Router, false)
    raise 'Router gem installed unexpectedly' if Gem::Specification.find_all_by_name('expect4r-routers').any?
    raise 'HighLine installed unexpectedly' if Gem::Specification.find_all_by_name('highline').any?
    begin
      require 'expect4r_routers'
      raise 'Application available in core-only installation'
    rescue LoadError
    end
    Expect4r.spawn(RbConfig.ruby, '-e', 'STDOUT.write "ready"') do |session|
      raise 'Installed core dialogue failed' unless session.expect!('ready', timeout: 5).match == 'ready'
    end
    Expect4r.spawn(RbConfig.ruby, '-e', 'STDOUT.write("x" * 128 + "END")', buffer_limit: 16) do |session|
      captured = session.capture_until!('END', retain: 4, total_timeout: 5)
      raise 'Installed streaming capture failed' unless captured.output_bytes == 128 && captured.output == 'xxxx'
    end
    require 'stringio'
    replay_source = StringIO.new
    recorder = Expect4r::Diagnostics::Recording.new(replay_source, session_id: 'package-check', label: nil)
    recorder.io(:rx, 'ready>')
    recorder.io(:tx, "go\r")
    recorder.io(:rx, 'ok>')
    recorder.event(session_id: 'package-check', event: :eof)
    recorder.finish(complete: true)
    Expect4r.replay(StringIO.new(replay_source.string), fragment_size: 1, require_all_reads: true) do |session|
      session.expect!('ready>')
      session.send_line('go')
      session.expect!('ok>')
      session.expect!(:eof)
    end
    puts 'Core-only installation: passed'
  CODE
  install.call(routers)
  run.call('-e', <<~'CODE', File.join(root, 'applications/routers/test/fixtures/router_cli.rb'))
    require 'expect4r_routers'
    raise 'Missing application factory' unless Expect4rRouters.respond_to?(:spawn)
    raise 'Core namespace polluted' if Expect4r.const_defined?(:Router, false)
    raise 'Legacy/HighLine loaded' if $LOADED_FEATURES.any? { |f| f.match?(/highline|expect4r\/legacy/) }
    Expect4rRouters.spawn(:ios, RbConfig.ruby, ARGV.fetch(0), user: 'lab', password: 'secret') do |router|
      raise 'Installed router dialogue failed' unless router.show!('version').success?
      raise 'Installed ping failed' unless router.ping('192.0.2.1').success?
    end
    puts 'Companion installation: passed'
  CODE
end
