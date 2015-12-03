require 'pathname'

module Mongodb
  def self.included(manifest)
    manifest.class_eval do
      extend ClassMethods
    end
  end

  module ClassMethods
    def mongo_yml
      @mongo_yml ||= Pathname.new(configuration[:deploy_to]) + 'shared/config/mongo.yml'
    end

    def mongo_rb
      @mongo_rb ||= Pathname.new(configuration[:deploy_to]) + 'current/config/initializers/mongo.rb'
    end

    def mongo_configuration
      configuration[:mongodb][rails_env.to_sym]
    end

    def mongo_template_dir
      @mongo_template_dir ||= Pathname.new(__FILE__).dirname.dirname.join('templates')
    end
  end

  # Define options for this plugin via the <tt>configure</tt> method
  # in your application manifest:
  #
  #   configure(:mongodb => {:foo => true})
  #
  # Then include the plugin and call the recipe(s) you need:
  #
  #  plugin :mongodb
  #  recipe :mongodb
  def mongodb(hash = {})
    if ubuntu_intrepid?
      # 10gen does not have repo support for < 9.04

      options = {
        :version => '1.4.4',
        :master? => false,
        :auth    => false,
        :slave?  => false,
        :slave   => {
          :auto_resync => false,
          :master_host => ''
        }
      }.with_indifferent_access.merge(hash.with_indifferent_access)

      file '/data',                :ensure => :directory
      file '/data/db',             :ensure => :directory
      file '/var/log/mongodb',     :ensure => :directory
      file '/opt/local',           :ensure => :directory
      package 'wget',              :ensure => :installed

      arch = Facter.value(:architecture)
      arch = 'i686' if arch == 'i386'

      exec 'install_mongodb',
        :command => [
          "wget http://downloads.mongodb.org/linux/mongodb-linux-#{arch}-#{options[:version]}.tgz",
          "tar xzf mongodb-linux-#{arch}-#{options[:version]}.tgz",
          "mv mongodb-linux-#{arch}-#{options[:version]} /opt/local/mongo-#{options[:version]}"
        ].join(' && '),
        :cwd => '/tmp',
        :creates => "/opt/local/mongo-#{options[:version]}/bin/mongod",
        :require => [
          file('/opt/local'),
          package('wget')
        ]

      file '/etc/init.d/mongodb',
        :mode => '744',
        :content => template(File.join(File.dirname(__FILE__), '..', 'templates', 'mongo.init.erb'), binding),
        :before => service('mongodb'),
        :checksum => :md5

      service "mongodb",
        :ensure => :running,
        :enable => true,
        :require => [
          file('/data/db'),
          file('/var/log/mongodb'),
          exec('install_mongodb')
        ],
        :before => exec('rake tasks')
    elsif ubuntu_lucid? || ubuntu_precise? || ubuntu_trusty?
      options = {
        :dbpath => '/var/lib/mongodb',
        :logpath => '/var/log/mongodb',
        :port => '27017',
        :bind_ip => '127.0.0.1',
        :cpu_logging => false,
        :verbose => false,
        :loglevel => '0',
        :journal => true,
        :version => '2.4.5'
      }.with_indifferent_access.merge(hash.with_indifferent_access)

      file '/etc/apt/sources.list.d/mongodb.list',
        :ensure => :present,
        :mode => '644',
        :content => template(File.join(File.dirname(__FILE__), '..', 'templates', 'mongodb.list.erb'), binding)

      exec '10gen apt-key',
        :command => 'apt-key adv --keyserver keyserver.ubuntu.com --recv 7F0CEB10',
        :unless => 'apt-key list | grep 7F0CEB10'

      exec 'apt-get update',
        :command => 'apt-get update',
        :require => [
          file('/etc/apt/sources.list.d/mongodb.list'),
          exec('10gen apt-key')
        ]

      if options[:version] =~ /^1.8.*$/
        package 'mongodb18-10gen',
          :alias => 'mongodb',
          :ensure => options[:version],
          :require => [ exec('apt-get update'), package('mongodb-10gen') ]

        package 'mongodb-10gen', :ensure => :absent
      elsif options[:version] =~ /^2.6.*$/
        package 'mongodb-org',
          :ensure => options[:version],
          :alias => 'mongodb',
          :require => [ exec('apt-get update'), package('mongodb-10gen') ]
        
        package 'mongodb-10gen', :ensure => :absent
      else
        package 'mongodb-10gen',
          :ensure => options[:version],
          :alias => 'mongodb',
          :require => [ exec('apt-get update'), package('mongodb18-10gen') ]

        package 'mongodb18-10gen', :ensure => :absent
      end

      mongod_name = if options[:version] =~ /^2.6.*$/
        'mongod'
      else
        'mongodb'
      end

      file "/etc/#{mongod_name}.conf",
        :ensure => :present,
        :mode => '644',
        :content => template(File.join(File.dirname(__FILE__), '..', 'templates', "#{mongod_name}.conf.erb"), binding),
        :before => service("#{mongod_name}"),
        :notify => service("#{mongod_name}")

      file "/etc/init/#{mongod_name}.conf",
        :ensure => :present,
        :mode => '644',
        :content => template(File.join(File.dirname(__FILE__), '..', 'templates', "#{mongod_name}.upstart.erb"), binding),
        :before => service("#{mongod_name}")

      file "/etc/init.d/#{mongod_name}",
        :ensure => :link, :target => '/lib/init/upstart-job',
        :before => service("#{mongod_name}")

      service "#{mongod_name}",
        :ensure => :running,
        :status => "initctl status #{mongod_name} | grep running",
        :start => "initctl start #{mongod_name}",
        :stop => "initctl stop #{mongod_name}",
        :restart => "initctl restart #{mongod_name}",
        :provider => :base,
        :enable => true,
        :require => [
          package('mongodb'),
          file("/etc/#{mongod_name}.conf"),
          file("/etc/init/#{mongod_name}.conf"),
        ],
        :before => exec('rake tasks')
    end
  end

  private
  def ubuntu_trusty?
    Facter.value(:lsbdistid) == 'Ubuntu' && Facter.value(:lsbdistrelease).to_f == 14.04
  end

  def ubuntu_precise?
    Facter.value(:lsbdistid) == 'Ubuntu' && Facter.value(:lsbdistrelease).to_f == 12.04
  end

  def ubuntu_lucid?
    Facter.value(:lsbdistid) == 'Ubuntu' && Facter.value(:lsbdistrelease).to_f == 10.04
  end

  def ubuntu_intrepid?
    Facter.value(:lsbdistid) == 'Ubuntu' && Facter.value(:lsbdistrelease).to_f == 8.10
  end
end
