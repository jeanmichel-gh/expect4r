require "test/unit"
require "misc/base"


require "test/unit"

class Base < Test::Unit::TestCase
  include Expect4r

  def test_add
    assert_equal( [], Base.all)
    Base.new
    assert_equal( 1, Base.all.size)
    Base.new 
    assert_equal( 2, Base.all.size)
  end

end

require 'misc/passwd'
require 'set'

class TestBaseLoginObject < Test::Unit::TestCase
  include Expect4r

  def setup
    @pwd  = "MySecretPassword"
    @cpwd = Expect4r.cipher(@pwd)
  end

  def test_we_are_not_caching_password_in_the_clear
    o = BaseLoginObject.new :telnet, :host=> '1.1.1.1', :user=> 'lab', :password=>'lab'
    assert_not_equal "lab", o.instance_eval { @pwd }
    o = BaseLoginObject.new :telnet, :host=> '1.1.1.1', :user=> 'lab', :password=>'lab'
    assert_not_equal "lab", o.instance_eval { @pwd }
    assert ! o.respond_to?(:spawnee_enable_password), "certain things are better kept private!"
    assert ! o.respond_to?(:spawnee_password), "certain things are better kept private!"
  end

  def test_that_default_enable_password_is_set_to_password
    o = BaseLoginObject.new :telnet, :host=> '1.1.1.1', :user=> 'lab', :password=>'lab'
    assert_equal(o.password, o.enable_password)
  end

  def test_dedicated_enable_password
    o = BaseLoginObject.new :telnet, :host=> '1.1.1.1', :user=> 'lab', :password=>'lab', :enable_password=>'LAB'
    assert_not_equal(o.password, o.enable_password)
  end

  def test_new_4_args
    o1 = BaseLoginObject.new :telnet, '1.1.1.1', 'lab', 'lab'
    o2 = BaseLoginObject.new :telnet, :host=> '1.1.1.1', :user=> 'lab', :password=>'lab'
    assert o1.cmp(o2)
  end

  def test_new_5th_arg_is_port_number
    o1 = BaseLoginObject.new :telnet, '1.1.1.1', 'lab', 'lab', 2001
    o2 = BaseLoginObject.new :telnet, :host=> '1.1.1.1', :user=> 'lab', :password=>'lab'
    assert ! o1.cmp(o2)
    o2.port=2001
    assert   o1.cmp(o2)
  end

  def test_new_5th_arg_is_enable_password
    o1 = BaseLoginObject.new :telnet, '1.1.1.1', 'lab', 'lab', 'secret'
    o2 = BaseLoginObject.new :telnet, :host=> '1.1.1.1', :user=> 'lab', :password=>'lab', :enable_password=>'secret'
    assert   o1.cmp(o2)
  end

  def test_new_6_args
    o1 = BaseLoginObject.new :telnet, '1.1.1.1', 'user', 'pwd', 'enable', 2001
    o2 = BaseLoginObject.new :telnet, :host=> '1.1.1.1', :user=> 'user', :password=>'pwd', :enable_password=>'enable', :port=>2001
    assert o1.cmp(o2)
  end

  def test_verify_private_spawnee_passord
    o1 = BaseLoginObject.new :telnet, '1.1.1.1', 'user', 'pwd', 'enable', 2001
    assert_equal("pwd", o1.instance_eval { spawnee_password})
  end

  def test_verify_private_spawnee_enable_passord
    o1 = BaseLoginObject.new :telnet, '1.1.1.1', 'user', 'pwd', 'enable', 2001
    assert_equal("enable", o1.instance_eval { spawnee_enable_password})
  end

end

