require "test/unit"
require "misc/passwd"

class TestMiscPasswd < Test::Unit::TestCase
  def test_cipher
    assert_not_equal 'my password', Interact.cipher('my password')
    assert_equal 'my password', Interact.decipher(Interact.cipher('my password'))
  end
end