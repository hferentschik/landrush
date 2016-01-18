require 'win32/registry'

module Landrush
  class RegistryConfig

    # Windows registry path under which network interface configuration is stored
    INTERFACES = 'SYSTEM\\CurrentControlSet\\Services\\Tcpip\\Parameters\\Interfaces'

    # Default access type
    KEY_READ = Win32::Registry::KEY_READ | 0x100

    # KEY_ALL_ACCESS enables you to write and delete keys
    # the default access is KEY_READ if you specify nothing
    ALL_ACCESS = Win32::Registry::KEY_ALL_ACCESS

    def initialize(env={})
      @env = env
    end

    def info(msg)
      @env[:ui].info("[landrush] #{msg}")
    end

    def self.update_network_adapter ip
      ensure_admin_privileges __FILE__.to_s, ip

      # TODO, Need to flesh this out
      Win32::Registry::HKEY_LOCAL_MACHINE.open(INTERFACES, ALL_ACCESS) do |reg|
        reg.each_key do |name|
          interface_path = INTERFACES + "\\#{name}"
          if registry_key_exists? interface_path, 'IPAddress'
            Win32::Registry::HKEY_LOCAL_MACHINE.open(interface_path, ALL_ACCESS) do |reg|
              interface_ip =  reg['IPAddress']
              if interface_ip[0] == ip
                p "Updating interface with IP #{ip}"
                reg['NameServer'] = '127.0.0.1'
                # TODO, Need to become a parameter
                reg['Domain'] = 'pdk.dev'
              end
              sleep 5
            end
          end
        end
      end
    end

    # private methods
    def self.ensure_admin_privileges(file, args)
      unless admin_mode?
        require 'win32ole'
        shell = WIN32OLE.new('Shell.Application')
        shell.ShellExecute('ruby', "#{file} #{args}", nil, 'runas', 1)
        exit
      end
    end

    def self.admin_mode?
      # If this registry query succeeds we assume we have Admin rights
      # http://stackoverflow.com/questions/8268154/run-ruby-script-in-elevated-mode/27954953
      (`reg query HKU\\S-1-5-19 2>&1` =~ /ERROR/).nil?
    end

    def self.registry_key_exists?(path, key)
      begin
        Win32::Registry::HKEY_LOCAL_MACHINE.open(path, KEY_READ) { |reg| reg[key] }
      rescue
        false
      end
    end

    private_class_method :ensure_admin_privileges, :admin_mode?, :registry_key_exists?
  end
end

# Only run the following code when this file is the main file being run
# instead of having been required or loaded by another file
if __FILE__ == $0
  # TODO, Add some argument checks
  Landrush::RegistryConfig.update_network_adapter ARGV[0]
end