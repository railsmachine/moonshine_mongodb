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

      if options[:version] =~ /^3.2.*$/
        mongodb32(options)
      elsif options[:version] =~ /^3.0.*$/
        mongodb30(options)
      elsif options[:version] =~ /^2.6.*$/
        mongodb26(options)
      else
        repo = "deb http://downloads-distro.mongodb.org/repo/ubuntu-upstart dist 10gen"
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
        else
          package 'mongodb-10gen',
            :ensure => options[:version],
            :alias => 'mongodb',
            :require => [ exec('apt-get update'), package('mongodb18-10gen') ]

          package 'mongodb18-10gen', :ensure => :absent
        end

        file '/etc/mongodb.conf',
          :ensure => :present,
          :mode => '644',
          :content => template(File.join(File.dirname(__FILE__), '..', 'templates', 'mongodb.conf.erb'), binding),
          :before => service('mongodb'),
          :notify => service('mongodb')

        file '/etc/init/mongodb.conf',
          :ensure => :present,
          :mode => '644',
          :content => template(File.join(File.dirname(__FILE__), '..', 'templates', 'mongodb.upstart.erb'), binding),
          :before => service('mongodb')

        file '/etc/init.d/mongodb',
          :ensure => :link, :target => '/lib/init/upstart-job',
          :before => service('mongodb')

        service 'mongodb',
          :ensure => :running,
          :status => 'initctl status mongodb | grep running',
          :start => 'initctl start mongodb',
          :stop => 'initctl stop mongodb',
          :restart => 'initctl restart mongodb',
          :provider => :base,
          :enable => true,
          :require => [
            package('mongodb'),
            file('/etc/mongodb.conf'),
            file('/etc/init/mongodb.conf'),
          ],
          :before => exec('rake tasks')
      end
    end
  end

  private
  def ubuntu_precise?
    Facter.value(:lsbdistid) == 'Ubuntu' && Facter.value(:lsbdistrelease).to_f == 12.04
  end

  def ubuntu_lucid?
    Facter.value(:lsbdistid) == 'Ubuntu' && Facter.value(:lsbdistrelease).to_f == 10.04
  end

  def ubuntu_intrepid?
    Facter.value(:lsbdistid) == 'Ubuntu' && Facter.value(:lsbdistrelease).to_f == 8.10
  end

  def mongodb26
    # TODO
    # repo = "deb http://downloads-distro.mongodb.org/repo/ubuntu-upstart dist 10gen"
  end

  def mongodb30
    # TODO
    # repo = "deb http://repo.mongodb.org/apt/ubuntu #{Facter.value(:lsbdistcodename)}/mongodb-org/3.0 multiverse"
  end

  def mongodb32(hash = {})
    puts "MongoDB 3.2: #{hash[:version]}"
    options = {
      :dbpath => '/var/lib/mongodb',
      :logpath => '/var/log/mongodb',
      :port => '27017',
      :bind_ip => '127.0.0.1',
      :cpu_logging => false,
      :verbose => false,
      :loglevel => '0',
      :journal => true,
      :version => '3.2.10'
    }.with_indifferent_access.merge(hash.with_indifferent_access)
    file '/etc/mongodb.conf', :ensure => :absent
    file '/etc/init/mongodb.conf', :ensure => :absent
    file '/etc/init.d/mongodb', :ensure => :absent

    repo = "deb http://repo.mongodb.org/apt/ubuntu #{Facter.value(:lsbdistcodename)}/mongodb-org/3.2 multiverse"
    file '/etc/apt/sources.list.d/mongodb.list',
      :ensure => :present,
      :mode => '644',
      :content => template(File.join(File.dirname(__FILE__), '..', 'templates', 'mongodb.list.erb'), binding)

    exec '10gen apt-key',
      :command => 'apt-key adv --keyserver keyserver.ubuntu.com --recv EA312927',
      :unless => 'apt-key list | grep EA312927'

    exec 'apt-get update',
      :command => 'apt-get update',
      :require => [
        file('/etc/apt/sources.list.d/mongodb.list'),
        exec('10gen apt-key')
      ]

    # package
    package 'mongodb-org',
      :ensure => options[:version],
      :alias => 'mongodb',
      :require => [ exec('apt-get update'), package('mongodb18-10gen'), package('mongodb-10gen') ]

    %w(mongodb-org-server mongodb-org-shell mongodb-org-mongos mongodb-org-tools).each do |pkg|
      package pkg,
        :ensure => options[:version],
        :require => [ exec('apt-get update'), package('mongodb18-10gen'), package('mongodb-10gen') ]
    end

    package 'mongodb18-10gen', :ensure => :absent
    package 'mongodb-10gen', :ensure => :absent

    # TODO: convert to YAML format
    file '/etc/mongod.conf',
      :ensure => :present,
      :mode => '644',
      :content => template(File.join(File.dirname(__FILE__), '..', 'templates', 'mongodb.conf.erb'), binding),
      :require => package('mongodb'),
      :before => service('mongod'),
      :notify => service('mongod')

    service 'mongod',
      :ensure=> :running,
      :provider => :upstart,
      :enable => true,
      :require => [
        package('mongodb'),
        file('/etc/mongodb.conf'),
        file('/etc/init/mongodb.conf'),
        file('/etc/init.d/mongodb')
      ],
      :before => exec('rake tasks')
  end
end
