require "test/unit"

require "router/cisco/iox/iox"

class TestRouterCiscoIoxIox < Test::Unit::TestCase
  def test_new_hash_terse
    x = Iox.new :ssh, 
                :host=> '1.1.1.1',
                :user=> 'username',
                :pwd=> 'lab',
                :method=> :ssh
    assert_equal '1.1.1.1', x.host
    assert_equal '1.1.1.1', x.hostname
    assert_equal 0, x.port
    assert_equal 'username', x.user
    assert_equal 'username', x.username
    assert_raise(NoMethodError) { x.pwd }
    assert_not_equal "lab", x.instance_eval { @pwd }
  end
  def test_new_hash
    x = Iox.new :ssh, 
                :hostname=> '1.1.1.1',
                :username=> 'username',
                :password=> 'lab'
    assert_equal '1.1.1.1', x.host
    assert_equal '1.1.1.1', x.hostname
    assert_equal 0, x.port
    assert_equal 'username', x.user
    assert_equal 'username', x.username
    assert_raise(NoMethodError) { x.pwd }
    assert_not_equal "lab", x.instance_eval { @pwd }
    assert_equal :ssh, x.instance_eval { @method }
  end
  def test_new
    x = Iox.new :telnet, '1.1.1.1 4002', 'username', 'lab'
    assert_equal '1.1.1.1', x.host
    assert_equal 4002, x.port
    assert_equal '1.1.1.1', x.hostname
    assert_equal 'username', x.user
    assert_equal 'username', x.username
    assert_raise(NoMethodError) { x.pwd }
    assert_not_equal "lab", x.instance_eval { @pwd }
    assert_equal :telnet, x.instance_eval { @method }
  end
  def test_new_ssh
    x = Iox.new_ssh :hostname=> '1.1.1.1'
    assert_equal '1.1.1.1', x.host
    assert_equal '1.1.1.1', x.hostname
    assert_equal 0, x.port
    assert_nil x.user
    assert_nil x.username
    assert_raise(NoMethodError) { x.pwd }
    assert_not_equal "lab", x.instance_eval { @pwd }
    assert_equal :ssh, x.instance_eval { @method }    
  end
  def test_new_telnet
    x = Iox.new_telnet :hostname=> '1.1.1.1'
    assert_equal '1.1.1.1', x.host
    assert_equal '1.1.1.1', x.hostname
    assert_equal 0, x.port
    assert_nil x.user
    assert_nil x.username
    assert_raise(NoMethodError) { x.pwd }
    assert_not_equal "lab", x.instance_eval { @pwd }
    assert_equal :telnet, x.instance_eval { @method }
  end
end