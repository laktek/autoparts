module Autoparts
  module Packages
    class Php5 < Package
      name 'php5'
      version '5.5.8'
      description 'PHP 5.5'
      source_url "http://us1.php.net/get/php-5.5.8.tar.gz/from/this/mirror"
      source_sha1 '19af9180c664c4b8f6c46fc10fbad9f935e07b52'
      source_filetype 'tar.gz'

      depends_on 'apache2'
      depends_on 'libmcrypt'

      def compile
        Dir.chdir('php-5.5.8') do
          args = [
            "--with-apxs2=#{apache2_dependency.bin_path + "apxs"}",
            "--with-mcrypt=#{get_dependency("libmcrypt").prefix_path}",
            # path
            "--prefix=#{prefix_path}",
            "--bindir=#{bin_path}",
            "--sbindir=#{bin_path}",
            "--sysconfdir=#{Path.etc + name}",
            "--libdir=#{lib_path}",
            "--includedir=#{include_path}",
            "--datarootdir=#{share_path}/#{name}",
            "--datadir=#{share_path}/#{name}",
            "--mandir=#{man_path}",
            "--docdir=#{doc_path}",
            # features
            "--enable-opcache",
            "--with-mysql",
            "--with-openssl",
            "--with-pgsql",
            "--with-readline",
          ]
          execute './configure', *args
          execute 'make'
        end
      end

      def install
        Dir.chdir('php-5.5.8') do
          execute 'make install'
          execute 'cp', 'php.ini-development', "#{lib_path}/php.ini"
          # force apache2 to rewrite its config to get a pristine config
          # because php will rewrite it
          apache2_dependency.rewrite_config
          # copy libphp5.so over to the package so its will be distributed with
          # the binary
          execute 'mv', "#{apache2_libphp5_path}", "#{lib_path + "libphp5.so"}"
        end
      end

      def post_install
        # copy libphp5.so over to apache modules path
        execute 'cp', "#{lib_path + "libphp5.so"}", "#{apache2_libphp5_path}"
        # write php5_config if not exist
        unless apache2_php5_config_path.exist?
          File.open(apache2_php5_config_path, "w") { |f| f.write php5_apache_config }
        end
        # copy php.ini over
        unless php5_ini_path.exist?
          execute 'cp', "#{lib_path}/php.ini", "#{php5_ini_path}"
        end
      end

      def php5_ini_path
        Path.etc + "php5" + "php.ini"
      end

      def apache2_dependency
        @apache2_dependency ||= get_dependency "apache2"
      end

      def apache2_libphp5_path
        apache2_dependency.prefix_path + "modules" + "libphp5.so"
      end

      def apache2_php5_config_path
        apache2_dependency.user_config_path + "php.conf"
      end

      def php5_apache_config
        <<-EOF.unindent
        LoadModule php5_module modules/libphp5.so
        AddHandler php5-script .php
        DirectoryIndex index.php
        EOF
      end
    end
  end
end
