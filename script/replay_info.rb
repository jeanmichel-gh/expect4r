# frozen_string_literal: true
require 'expect4r'
abort 'Usage: bundle exec ruby -Ilib script/replay_info.rb recording.jsonl' unless ARGV.size == 1
trace = Expect4r::ReplayTrace.load(ARGV.fetch(0))
puts JSON.pretty_generate(trace.summary)
