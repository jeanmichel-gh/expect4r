# frozen_string_literal: true
require 'expect4r_routers/router'

module Expect4rRouters
  class << self
    def open(...) = Router.open(...)
    def spawn(...) = Router.spawn(...)
    def attach(...) = Router.attach(...)
  end
end
