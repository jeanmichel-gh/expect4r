require 'rubygems'

begin

  require 'openssl'
  require 'digest/sha1'
  
  module Expect4r
    def self.cipher(this, pwd='expect4r')
      c = OpenSSL::Cipher::Cipher.new("aes-256-cbc")
      c.encrypt
      c.key = key = Digest::SHA1.hexdigest(pwd)
      e = c.update(this)
      e << c.final
    end
    def self.decipher(cipher,pwd='expect4r')
      c = OpenSSL::Cipher::Cipher.new("aes-256-cbc")
      c.decrypt
      c.key = key = Digest::SHA1.hexdigest(pwd)
      d = c.update(cipher)
      d << c.final
    end
  end
  
rescue LoadError => e
  
  module Expect4r
    def self.cipher(arg, pwd='')
      arg
    end
    def self.decipher(arg,pwd='')
      arg
    end
  end

end