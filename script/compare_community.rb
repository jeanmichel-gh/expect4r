# Optional smoke test; run outside the expect4r Bundler environment.
# gem install ruby_expect -v 1.7.5
# ruby script/compare_community.rb ruby_expect
# Ruby 3.4+: gem install expect-pty -v 0.9.6
# ruby script/compare_community.rb expect-pty
abort 'Choose ruby_expect or expect-pty' unless %w[ruby_expect expect-pty].include?(ARGV[0])
require 'rbconfig'
require 'shellwords'
require 'timeout'
if ARGV[0] == 'ruby_expect'
  require 'ruby_expect'
  Timeout.timeout(5) do
    code = '$stdout.sync=true; print "first\nready>"; name=gets.strip; print "hello #{name}>"; sleep 0.1'
    session = RubyExpect::Expect.spawn([RbConfig.ruby, '-e', code].shelljoin)
    session.timeout = 2
    raise 'multiline failed' unless session.expect(/first\r\nready>/) == 0
    session.send('Ruby')
    raise 'reply failed' unless session.expect('hello Ruby>') == 0
    session.soft_close
  end
  puts "ruby_expect #{Gem.loaded_specs.fetch("ruby_expect").version}: multiline + reply passed on Ruby #{RUBY_VERSION}"
else
  require 'expect/pty'
  Timeout.timeout(5) do
    code = '$stdout.sync=true; print "first\nready>"; name=gets.strip; print "hello #{name}>"; sleep 0.1'
    Expect.spawn(RbConfig.ruby, '-e', code) do |session|
      raise 'multiline failed' unless session.expect(/first\r\nready>/, timeout: 2).matched?
      session.puts('Ruby')
      raise 'reply failed' unless session.expect('hello Ruby>', timeout: 2).matched?
    end
  end
  puts "expect-pty #{Expect::VERSION}: multiline + reply passed on Ruby #{RUBY_VERSION}"
end
