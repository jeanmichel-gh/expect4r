
autoload :Iox, 'router/cisco/iox/iox'
autoload :Ios, 'router/cisco/ios/ios'
autoload :J, 'router/juniper/junos/junos'
autoload :Shell, 'misc/shell'


if __FILE__ == $0
  p Iox.new_ssh 'hostname', 'username'
  p Iox.new_telnet 'hostname', 'username'
  p Ios.new_ssh 'hostname', 'username'
  p J.new_ssh 'hostname', 'username'
  p Shell.new
end
