# frozen_string_literal: true
require 'expect4r/router'
require 'rbconfig'
simulator = File.expand_path('../test/fixtures/router_cli.rb', __dir__)
Expect4r::Router.spawn(:ios, RbConfig.ruby, simulator,
                       user: 'lab', password: -> { 'secret' }) do |router|
  puts router.exec!('show version').output
  puts router.exec!('show paged').output
  router.configure { |config| config.command 'description "written by Ruby"' }
  puts router.exec!('show running-config').output
end
