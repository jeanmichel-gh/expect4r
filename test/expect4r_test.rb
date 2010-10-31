require 'expect4r'
require "test/unit"
class TestAutoload < Test::Unit::TestCase
  include Expect4r
  def test_autoload
    assert Expect4r::Iox.new_ssh 'hostname', 'username'
    assert Expect4r::Iox.new_telnet 'hostname', 'username'
    assert Expect4r::Ios.new_ssh 'hostname', 'username'
    assert Expect4r::J.new_ssh 'hostname', 'username'
    assert Expect4r::Shell.new    
  end
end
