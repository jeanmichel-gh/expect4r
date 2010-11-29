require "test/unit"
require "misc/passwd"

class TestMiscPasswd < Test::Unit::TestCase
  def test_cipher
    assert_not_equal 'my password', Expect4r.cipher('my password')
    assert_equal 'my password', Expect4r.decipher(Expect4r.cipher('my password'))
    assert_not_equal 'my password', Expect4r.cipher('my password', 'abcdef')
    assert_equal 'my password', Expect4r.decipher(Expect4r.cipher('my password'))
  end
end