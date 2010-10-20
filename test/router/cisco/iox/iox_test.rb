require "test/unit"

require "router/cisco/iox/iox"

class TestRouterCiscoIoxIox < Test::Unit::TestCase
  def test_new
    x = Iox.new :host=> '1.1.1.1', 
                :user=> 'username', 
                :method=> :ssh
    p x
  end
end