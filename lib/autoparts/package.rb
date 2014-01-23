require 'unindent/unindent'
require 'net/http'
require 'etc'

module Autoparts
  class Package
    BINARY_HOST = 'http://parts.nitrous.io'.freeze
    WEB_HOOK_URL = 'https://www.nitrous.io/autoparts/webhook'.freeze
    include PackageDeps

    class << self
      def installed
        hash = {}
        Path.packages.each_child do |pkg|
          if pkg.directory?
            pkg.each_child do |ver|
              if ver.directory? && !ver.children.empty?
                hash[pkg.basename.to_s] ||= []
                hash[pkg.basename.to_s].push ver.basename.to_s
              end
            end
          end
        end
        hash
      end

      def installed?(name)
        installed.has_key? name
      end

      def packages
        @@packages ||= {}
      end

      def factory(name)
        begin
          require "autoparts/packages/#{name}"
        rescue LoadError
        end
        if package_class = packages[name]
          package_class.new
        else
          raise Autoparts::PackageNotFoundError.new(name)
        end
      end

      def name(val)
        @name = val
        packages[val] = self
      end

      def version(val)
        @version = val
      end

      def description(val)
        @description = val
      end

      def source_url(val)
        @source_url = val
      end

      def source_sha1(val)
        @source_sha1 = val
      end

      def source_filetype(val)
        @source_filetype = val
      end
    end

    def initialize
      @source_install = false
    end

    def name
      self.class.instance_variable_get(:@name)
    end

    def version
      self.class.instance_variable_get(:@version)
    end

    def description
      self.class.instance_variable_get(:@description)
    end

    def name_with_version
      "#{name}-#{version}"
    end

    def source_url
      self.class.instance_variable_get(:@source_url)
    end

    def source_sha1
      self.class.instance_variable_get(:@source_sha1)
    end

    def source_filetype
      self.class.instance_variable_get(:@source_filetype)
    end

    def binary_present?
      @binary_present = (remote_file_exists?(binary_url) && remote_file_exists?(binary_sha1_url)) if @binary_present.nil?
      @binary_present
    end

    def binary_url
      "#{BINARY_HOST}/#{name_with_version}-binary.tar.gz"
    end

    def binary_sha1_url
      "#{BINARY_HOST}/#{binary_sha1_filename}"
    end

    def binary_sha1
      if binary_present?
        download binary_sha1_url, binary_sha1_path
        File.read(binary_sha1_path.to_s).strip
      else
        raise BinaryNotPresentError.new(name)
      end
    end

    def user
      Etc.getlogin
    end

    def prefix_path
      Path.packages + name + version
    end

    %w(bin sbin include lib libexec share).each do |d|
      define_method :"#{d}_path" do
        prefix_path + d
      end
    end

    def info_path
      share_path + 'info'
    end

    def man_path
      share_path + 'man'
    end

    (1..8).each do |i|
      define_method :"man#{i}_path" do
        man_path + "man#{i}"
      end
    end

    def doc_path
      share_path + 'doc' + name
    end

    def execute(*args)
      args = args.map(&:to_s)
      unless system(*args)
        raise ExecutionFailedError.new args.join(' ')
      end
    end

    def archive_filename
      name_with_version + (@source_install ? ".#{source_filetype}" : '-binary.tar.gz')
    end

    def binary_sha1_filename
      name_with_version + '-binary.sha1'
    end

    def temporary_archive_path
      Path.tmp + archive_filename
    end

    def binary_sha1_path
      Path.tmp + binary_sha1_filename
    end

    def archive_path
      Path.archives + archive_filename
    end

    def extracted_archive_path
      Path.tmp + "#{name_with_version}"
    end

    def download_archive
      url  = @source_install ? source_url  : binary_url
      sha1 = @source_install ? source_sha1 : binary_sha1

      download url, archive_path, sha1
    end

    def extract_archive
      extracted_archive_path.rmtree if extracted_archive_path.exist?
      extracted_archive_path.mkpath
      Dir.chdir(extracted_archive_path) do
        if @source_install
          case source_filetype
          when 'tar', 'tar.gz', 'tar.bz2', 'tar.bz', 'tgz', 'tbz2', 'tbz'
            execute 'tar', 'xf', archive_path
          when 'zip'
            execute 'unzip', '-qq', archive_path
          else
            execute 'cp', archive_path, extracted_archive_path
          end
        else
          execute 'tar', 'xf', archive_path
        end
      end
    end

    def symlink_recursively(from, to, options={}) # Pathname, Pathname
      only_executables = !!options[:only_executables]
      to.mkpath unless to.exist?
      from.each_child do |f|
        t = to + f.basename
        if f.directory? && !f.symlink?
          symlink_recursively f, t, options
        else
          if !only_executables || (only_executables && (f.executable? || f.symlink?))
            t.rmtree if t.exist?
            t.make_symlink(f)
          end
        end
      end if from.directory? && from.executable?
    end

    def unsymlink_recursively(from, to) # Pathname, Pathname
      if to.exist?
        from.each_child do |f|
          t = to + f.basename
          if f.directory? && !f.symlink?
            unsymlink_recursively f, t
          else
            t.rmtree if t.exist?
          end
        end
        to.rmtree if to.children.empty?
      end if from.directory? && from.executable?
    end

    def archive_installed_package
      @source_install = false
      Dir.chdir(prefix_path) do
        execute "tar -c . | gzip -n > #{temporary_archive_path}"
      end
      execute 'mv', temporary_archive_path, archive_path
    end

    def perform_install(source_install=false)
      begin
        ENV['CPPFLAGS'] = '-D_FORTIFY_SOURCE=2'
        ENV['CHOST'] = 'x86_64-pc-linux-gnu'
        ENV['CFLAGS'] = '-march=x86-64 -mtune=generic -O2 -pipe -fstack-protector --param=ssp-buffer-size=4'
        ENV['CXXFLAGS'] = ENV['CFLAGS']
        ENV['LDFLAGS'] = '-Wl,-O1,--sort-common,--as-needed,-z,relro'
        ENV['MAKEFLAGS'] = '-j2'

        if !source_install && !Util.binary_package_compatible?
          puts "Warning: This system is incompatible with Nitrous.IO binary packages; installing from source."
          source_install = true
        end

        @source_install = source_install ||= (binary_present? == false)

        unless File.exist? archive_path
          puts "=> Downloading #{@source_install ? source_url : binary_url}..."
          download_archive
        end
        puts "=> Extracting archive..."
        extract_archive

        Path.etc
        Path.var

        if @source_install # install from source
          Dir.chdir(extracted_archive_path) do
            puts "=> Compiling..."
            compile
            puts "=> Installing..."
            install
          end
        else # install using pre-compiled binary
          puts "=> Installing..."
          prefix_path.rmtree if prefix_path.exist?
          prefix_path.parent.mkpath
          execute 'mv', extracted_archive_path, prefix_path
        end

        extracted_archive_path.rmtree if extracted_archive_path.exist?

        Dir.chdir(prefix_path) do
          post_install
          puts '=> Symlinking...'
          symlink_recursively(bin_path,     Path.bin,  only_executables: true)
          symlink_recursively(sbin_path,    Path.sbin, only_executables: true)
          symlink_recursively(lib_path,     Path.lib)
          symlink_recursively(include_path, Path.include)
          symlink_recursively(share_path,   Path.share)
        end
      rescue => e
        archive_path.unlink if e.kind_of? VerificationFailedError
        prefix_path.rmtree if prefix_path.exist?
        raise e
      else
        puts "=> Installed #{name} #{version}\n"
        puts tips
        call_web_hook :installed
      end
    end

    def perform_uninstall
      begin
        if respond_to?(:stop) && respond_to?(:running?) && running?
          puts "=> Stopping #{name}..."
          stop
        end
      rescue
      end
      puts '=> Removing symlinks...'
      unsymlink_recursively(bin_path,     Path.bin)
      unsymlink_recursively(sbin_path,    Path.sbin)
      unsymlink_recursively(lib_path,     Path.lib)
      unsymlink_recursively(include_path, Path.include)
      unsymlink_recursively(share_path,   Path.share)

      puts '=> Uninstalling...'
      prefix_path.rmtree if prefix_path.exist?
      parent = prefix_path.parent
      parent.rmtree if parent.children.empty?
      post_uninstall

      puts "=> Uninstalled #{name} #{version}\n"
      call_web_hook :uninstalled
    end

    def upload_archive
      binary_file_name = "#{name_with_version}-binary.tar.gz"
      binary_sha1_file_name = "#{name_with_version}-binary.sha1"

      binary_path = Path.archives + binary_file_name
      binary_sha1_path = Path.archives + binary_sha1_file_name

      if File.exists?(binary_path) && File.exists?(binary_sha1_path)
        puts "=> Uploading #{name} #{version}..."
        [binary_file_name, binary_sha1_file_name].each do |f|
          local_path = Path.archives + f
          `s3cmd put --acl-public --guess-mime-type #{local_path} s3://nitrousio-autoparts-use1/#{f}`
        end
        puts "=> Done"
      else
        puts "=> Error: Can't find package, archive it by running AUTOPARTS_DEV=1 parts archive #{name}"
      end
    end

    def archive_installed
      puts "=> Archiving #{name} #{version}..."
      archive_installed_package
      file_size = archive_path.size
      puts "=> Archived: #{archive_path}"
      puts "Size: #{archive_path.size} bytes (#{sprintf "%.2f MiB", file_size / 1024.0 / 1024.0})"
      sha1 = Util.sha1 archive_path
      # Write the SHA1 to the archive_path too
      File.open(File.join(Path.archives, "#{name_with_version}-binary.sha1"), 'w') { |f| f.puts (sha1) }
      puts "SHA1: #{sha1}"
    end

    def download(url, to, sha1=nil)
      tmp_download_path = Path.tmp + ("#{to.basename}.partsdownload")
      execute 'curl', url, '-L', '-o', tmp_download_path
      if sha1 && sha1 != Util.sha1(tmp_download_path)
        raise VerificationFailedError
      end
      execute 'mv', tmp_download_path, to
    end

    def remote_file_exists?(url)
      `curl -IsL -w \"%{http_code}\" '#{url}' -o /dev/null 2> /dev/null`.strip == '200'
    end

    # notify the web IDE when a package is installed / uninstalled
    def call_web_hook(action)
      container = `hostname`.strip
      Net::HTTP.post_form URI(WEB_HOOK_URL), 'type' => action.to_s, 'name' => self.name, 'version' => self.version, 'container' => container
    end

    # -- implement these methods --
    def compile # compile source code - runs in source directory
    end

    def install # install compiled code - runs in source directory
    end

    def post_install # run post install commands - runs in installed package directory
    end

    def post_uninstall # run post uninstall commands
    end

    def purge # remove leftover config/data files
    end

    #def start
    #end

    #def stop
    #end

    #def running?
    #end

    def tips
      ''
    end

    def information
      tips
    end
    # -----
  end
end
