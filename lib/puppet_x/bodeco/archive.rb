# frozen_string_literal: true

require 'digest'
require 'puppet/util/execution'
require 'shellwords'

module PuppetX
  module Bodeco
    class Archive
      def initialize(file)
        @file = file
        @file_path =  if Facter.value(:osfamily) == 'windows'
                        "\"#{file}\""
                      else
                        Shellwords.shellescape file
                      end
      end

      def checksum(type)
        return nil if type == :none

        digest = Digest.const_get(type.to_s.upcase)
        digest.file(@file).hexdigest
      rescue LoadError
        raise $ERROR_INFO, "invalid checksum type #{type}. #{$ERROR_INFO}", $ERROR_INFO.backtrace
      end

      def root_dir
        if Facter.value(:osfamily) == 'windows'
          'C:\\'
        else
          '/'
        end
      end

      def extract(path = root_dir, opts = {})
        opts = {
          custom_command: nil,
          options: '',
          uid: nil,
          gid: nil
        }.merge(opts)

        custom_command = opts.fetch(:custom_command, nil)
        options = opts.fetch(:options)
        cmd = if custom_command&.include?('%s')
                custom_command % @file_path
              elsif custom_command
                "#{custom_command} #{options} #{@file_path}"
              else
                command(options)
              end

        Puppet.debug("Archive extracting #{@file} in #{path}: #{cmd}")
        File.chmod(0o644, @file) if opts[:uid] || opts[:gid]
        Puppet::Util::Execution.execute(cmd, uid: opts[:uid], gid: opts[:gid], cwd: path, failonfail: true, squelch: false, combine: true)
      end

      private

      def win_7zip
        if system('where 7z.exe')
          '7z.exe'
        elsif File.exist?('C:\Program Files\7-Zip\7z.exe')
          'C:\Program Files\7-Zip\7z.exe'
        elsif File.exist?('C:\Program Files (x86)\7-zip\7z.exe')
          'C:\Program Files (x86)\7-Zip\7z.exe'
        elsif @file_path =~ %r{.zip"$}
          # Fallback to powershell for zipfiles - this works with windows
          # 2012+ if your powershell/.net is too old the script will fail
          # on execution and ask user to install 7zip.
          # We have to manually extract each entry in the zip file
          # to ensure we extract fresh copy because `ExtractToDirectory`
          # method does not support overwriting
          ps = <<-END
          try {
              Add-Type -AssemblyName System.IO.Compression.FileSystem -erroraction "silentlycontinue"
              $zipFile = [System.IO.Compression.ZipFile]::openread(#{@file_path})
              foreach ($zipFileEntry in $zipFile.Entries) {
                  $pwd = (Get-Item -Path "." -Verbose).FullName
                  $outputFile = [io.path]::combine($pwd, $zipFileEntry.FullName)
                  $dir = ([io.fileinfo]$outputFile).DirectoryName

                  if (-not(Test-Path -type Container -path $dir)) {
                      mkdir $dir
                  }
                  if ($zipFileEntry.Name -ne "") {
                      write-host "[extract] $zipFileEntry.Name"
                      [System.IO.Compression.ZipFileExtensions]::ExtractToFile($zipFileEntry, $outputFile, $true)
                  }
              }
          } catch [System.invalidOperationException] {
              write-error "Your OS does not support System.IO.Compression.FileSystem - please install 7zip"
          }
          END

          "powershell -command #{ps.gsub(%r{"}, '\\"').gsub(%r{\n}, '; ')}"
        else
          raise StandardError, '7z.exe not available'
        end
      end

      def command(options)
        if Facter.value(:osfamily) == 'windows'
          opt = parse_flags('x -aoa', options, '7z')
          cmd = win_7zip
          cmd =~ %r{7z.exe} ? "#{cmd} #{opt} #{@file_path}" : cmd
        else
          case @file
          when %r{\.tar$}
            opt = parse_flags('xf', options, 'tar')
            "tar #{opt} #{@file_path}"
          when %r{(\.tgz|\.tar\.gz)$}
            case Facter.value(:osfamily)
            when 'Solaris', 'AIX'
              gunzip_opt = parse_flags('-dc', options, 'gunzip')
              tar_opt = parse_flags('xf', options, 'tar')
              "gunzip #{gunzip_opt} #{@file_path} | tar #{tar_opt} -"
            else
              opt = parse_flags('xzf', options, 'tar')
              "tar #{opt} #{@file_path}"
            end
          when %r{(\.tbz|\.tar\.bz2)$}
            case Facter.value(:osfamily)
            when 'Solaris', 'AIX'
              bunzip_opt = parse_flags('-dc', options, 'bunzip')
              tar_opt = parse_flags('xf', options, 'tar')
              "bunzip2 #{bunzip_opt} #{@file_path} | tar #{tar_opt} -"
            else
              opt = parse_flags('xjf', options, 'tar')
              "tar #{opt} #{@file_path}"
            end
          when %r{(\.txz|\.tar\.xz)$}
            unxz_opt = parse_flags('-dc', options, 'unxz')
            tar_opt = parse_flags('xf', options, 'tar')
            "unxz #{unxz_opt} #{@file_path} | tar #{tar_opt} -"
          when %r{\.gz$}
            opt = parse_flags('-d', options, 'gunzip')
            "gunzip #{opt} #{@file_path}"
          when %r{(\.zip|\.war|\.jar)$}
            opt = parse_flags('-o', options, 'zip')
            "unzip #{opt} #{@file_path}"
          when %r{(\.bz2)$}
            opt = parse_flags('-d', options, 'bunzip2')
            "bunzip2 #{opt} #{@file_path}"
          when %r{(\.tar\.Z)$}
            tar_opt = parse_flags('xf', options, 'tar')
            "uncompress -c #{@file_path} | tar #{tar_opt} -"
          else
            raise NotImplementedError, "Unknown filetype: #{@file}"
          end
        end
      end

      def parse_flags(default, options, command = nil)
        case options
        when :undef
          default
        when ::String
          options
        when ::Hash
          options[command]
        else
          raise ArgumentError, "Invalid options for command #{command}: #{options.inspect}"
        end
      end
    end
  end
end
