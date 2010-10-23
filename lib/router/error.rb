module Expect4r::Router
module Error
  class RouterError < RuntimeError
    def initialize(rname, msg)
      @rname = rname
      @msg = msg
    end
    def err_msg
      "#{@rname} [Error] : #{@msg}"
    end
  end

  class SyntaxError < RouterError
    def err_msg
      "#{@rname} [SyntaxError] : #{@msg}"
    end
  end

  class SemanticError < RouterError
    def err_msg
      "#{@rname} [SemanticError] : #{@msg}"
    end
  end

  class PingError < RuntimeError
    attr_reader :rname, :dest, :exp_pct, :act_pct, :sent, :recv
    def initialize(rname, dest, exp_pct, act_pct, sent, recv, output)
      @rname, @dest, @exp_pct, @act_pct, @sent, @recv = rname, dest, exp_pct, act_pct, sent, recv
    end
    def err_msg
      "#{@rname} [PingError] : failed to ping #{@dest}, expected/actual pct: #{@exp_pct}/#{@act_pct}"
    end
  end
end
end


if __FILE__ == $0

  require "test/unit"

  # require "router/error"

  class TestRouterError < Test::Unit::TestCase
    include Expect4r::Router::Error
    def test_raise
      assert_raise(RouterError) {raise RouterError.new('paris','show bogus command')} 
      assert_err_msg 'paris [Error] : show bogus command', lambda {raise RouterError.new('paris','show bogus command')}
      assert_err_msg 'paris [SyntaxError] : show bogus command', lambda {raise SyntaxError.new('paris','show bogus command')}
      assert_err_msg 'paris [SemanticError] : show bogus command', lambda {raise SemanticError.new('paris','show bogus command')}
      assert_err_msg 'paris [PingError] : failed to ping 1.1.1.1, expected/actual pct: 100/90', lambda {raise PingError.new('paris','1.1.1.1', 100, 90, 10, 9, '')}
      assert_equal 100, exception(lambda {raise PingError.new('paris','1.1.1.1', 100, 90, 10, 9,'')}).exp_pct
      assert_equal 'paris', exception(lambda {raise PingError.new('paris','1.1.1.1', 100, 90, 10, 9,'')}).rname
    end

    private

    def assert_err_msg(err_msg, block)
      begin 
        block.call 
      rescue RouterError, PingError => re
        assert_equal err_msg, re.err_msg
      end
    end

    def exception(block)
      begin 
        block.call 
      rescue RouterError, PingError => re
        re
      end
    end

  end

end
