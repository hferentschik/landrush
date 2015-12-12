require 'rubydns'
require 'childprocess'
require_relative 'store'

module Landrush
  class Server
    Name = Resolv::DNS::Name
    IN   = Resolv::DNS::Resource::IN

    def self.working_dir
      @working_dir ||= Pathname(File.expand_path('~/.vagrant.d/data/landrush')).tap(&:mkpath)
    end

    def self.working_dir=(working_dir)
      @working_dir = Pathname(working_dir).tap(&:mkpath)
    end

    def self.log_directory
      File.join(working_dir, "log")
    end

    def self.log_file
      File.join(log_directory, "landrush.log")
    end

    def self.port
      @port ||= 10053
    end

    def self.port=(port)
      @port = port
    end

    def self.upstream_servers
      # Doing collect to cast protocol to symbol because JSON store doesn't know about symbols
      @upstream_servers ||= Store.config.get('upstream').collect {|i| [i[0].to_sym, i[1], i[2]]}
    end

    def self.interfaces
      [
        [:udp, "0.0.0.0", port],
        [:tcp, "0.0.0.0", port]
      ]
    end

    def self.upstream
      @upstream ||= RubyDNS::Resolver.new(upstream_servers)
    end

    # Used to start the Landrush DNS server as a child process using ChildProcess gem
    def self.start
      # Build the command line for the new process
      process = ChildProcess.build("ruby", "#{__FILE__}", "#{@port}", "#{@working_dir}")

      # Set the working directory for the process
      process.cwd = working_dir.to_path

      # Setup IO
      ensure_path_exits(log_file)
      log = File.open(log_file, "w+")
      process.io.stdout = process.io.stderr = log

      # Make sure the process keeps running
      process.detach = true

      # Make sure process gets a new group
      process.leader = true

      # Start the process
      process.start

      # Record the process pid
      write_pid(process.pid)
    end

    def self.stop
      puts "Stopping daemon..."

      # Check if the pid file exists...
      unless File.file?(pid_file)
        puts "Pid file #{pid_file} not found. Is the daemon running?"
        return
      end

      pid = read_pid

      # Check if the daemon is already stopped...
      unless running?
        puts "Pid #{pid} is not running. Has daemon crashed?"
        return
      end

      puts "Killing process"

      pgid = -Process.getpgid(pid)
      Process.kill("INT", pgid)
      sleep 0.1

      sleep 1 if running?

      # Kill/Term loop - if the daemon didn't die easily, shoot
      # it a few more times.
      attempts = 5
      while running? and attempts > 0
        sig = (attempts >= 2) ? "KILL" : "TERM"

        puts "Sending #{sig} to process group #{pgid}..."
        Process.kill(sig, pgid)

        attempts -= 1
        sleep 1
      end

      # If after doing our best the daemon is still running (pretty odd)...
      if running?
        puts "Daemon appears to be still running!"
        return
      end

      # Otherwise the daemon has been stopped.
      delete_pid_file
    end

    def self.restart
      stop
      start
    end

    def self.pid
      IO.read(pid_file).to_i rescue nil
    end

    def self.running?
      pid = read_pid

      return false if pid == nil

      gpid = Process.getpgid(pid) rescue nil

      return gpid != nil ? true : false
    end

    def self.status
      case process_status
      when :running
        puts "Daemon status: running pid=#{ProcessFile.recall(daemon)}"
      when :unknown
        if daemon.crashed?
          puts "Daemon status: crashed"
          $stdout.flush
          $stderr.puts "Dumping daemon crash log:"
          daemon.tail_log($stderr)
        else
          puts "Daemon status: unknown"
        end
      when :stopped
        puts "Daemon status: stopped"
      end
    end

    def self.run(port, working_dir)
      server = self
      server.port = port
      server.working_dir = working_dir

      # Start the DNS server
      RubyDNS::run_server(:listen => interfaces) do
        self.logger.level = Logger::INFO

        match(/.*/, IN::A) do |transaction|
          host = Store.hosts.find(transaction.name)
          if host
            server.check_a_record(host, transaction)
          else
            transaction.passthrough!(server.upstream)
          end
        end

        match(/.*/, IN::PTR) do |transaction|
          host = Store.hosts.find(transaction.name)
          if host
            transaction.respond!(Name.create(Store.hosts.get(host)))
          else
            transaction.passthrough!(server.upstream)
          end
        end

        # Default DNS handler
        otherwise do |transaction|
          transaction.passthrough!(server.upstream)
        end
      end
    end

    def self.check_a_record(host, transaction)
      value = Store.hosts.get(host)
      if (IPAddr.new(value) rescue nil)
        name = transaction.name =~ /#{host}/ ? transaction.name : host
        transaction.respond!(value, {:ttl => 0, :name => name})
      else
        transaction.respond!(Name.create(value), resource_class: IN::CNAME, ttl: 0)
        check_a_record(value, transaction)
      end
    end

    # private methods

    def self.write_pid(pid)
      ensure_path_exits(pid_file)
      File.open(pid_file, 'w') {|f| f << pid.to_s}
    end

    def self.read_pid
      IO.read(pid_file).to_i rescue nil
    end

    def self.delete_pid_file
      if File.exist? pid_file
        FileUtils.rm(pid_file)
      end
    end

    def self.pid_file
      File.join(working_dir, 'run', 'landrush.pid')
    end

    def self.process_status
        if File.exist? pid_file
          return running? ? :running : :unknown
        else
          return :stopped
        end
    end

    def self.ensure_path_exits(file_name)
      dirname = File.dirname(file_name)
      unless File.directory?(dirname)
        FileUtils.mkdir_p(dirname)
      end
    end

    private_class_method :write_pid, :read_pid, :delete_pid_file,
     :pid_file, :process_status, :ensure_path_exits
  end
end

# Only run the following code when this file is the main file being run
# instead of having been required or loaded by another file
if __FILE__ == $0
  # TODO - Add some argument checks
  Landrush::Server.run(ARGV[0], ARGV[1])
end
