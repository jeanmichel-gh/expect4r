require 'rubygems'
require 'openssl'
require 'digest/sha1'
module Expect4r

  def self.cipher(this, pwd='interact')
    c = OpenSSL::Cipher::Cipher.new("aes-256-cbc")
    c.encrypt
    # your pass is what is used to encrypt/decrypt
    c.key = key = Digest::SHA1.hexdigest(pwd)
    # c.iv = iv = c.random_iv
    e = c.update(this)
    e << c.final
  end
  def self.decipher(cipher,pwd='interact')
    c = OpenSSL::Cipher::Cipher.new("aes-256-cbc")
    c.decrypt
    c.key = key = Digest::SHA1.hexdigest(pwd)
    # c.iv = iv
    d = c.update(cipher)
    d << c.final
  end
end

__END__



c = OpenSSL::Cipher::Cipher.new("aes-256-cbc")
c.encrypt
# your pass is what is used to encrypt/decrypt
c.key = key = Digest::SHA1.hexdigest("yourpass")
c.iv = iv = c.random_iv
e = c.update("crypt this")
e << c.final
puts "encrypted: #{e}\n"
c = OpenSSL::Cipher::Cipher.new("aes-256-cbc")
c.decrypt
c.key = key
c.iv = iv
d = c.update(e)
d << c.final
puts "decrypted: #{d}\n"
