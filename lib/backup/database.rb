# frozen_string_literal: true

# Copyright (c) 2011-present GitLab B.V.

# Portions of this software are licensed as follows:

# * All content residing under the "doc/" directory of this repository is licensed under "Creative Commons: CC BY-SA 4.0 license".
# * All content that resides under the "ee/" directory of this repository, if that directory exists, is licensed under the license defined in "ee/LICENSE".
# * All client-side JavaScript (when served directly or after being compiled, arranged, augmented, or combined), is licensed under the "MIT Expat" license.
# * All third party components incorporated into the GitLab Software are licensed under the original license provided by the owner of the applicable component.
# * Content outside of the above mentioned directories or restrictions above is available under the "MIT Expat" license as defined below.

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

module Backup
  class Database
    include Backup::Helper

    class Error < StandardError; end

    def self.dump
      new.dump
    end

    def self.restore
      new.restore
    end

    def dump
      FileUtils.mkdir_p(File.dirname(db_file_name))
      FileUtils.rm_f(db_file_name)

      compress_rd, compress_wr = IO.pipe
      compress_pid = spawn(gzip_cmd, in: compress_rd, out: [db_file_name, 'w', 0600])
      compress_rd.close

      dump_pid =
        case config["adapter"]
        when "postgresql" then
          puts_time("Dumping PostgreSQL database #{config['database']} ... ", false)
          pg_env
          pgsql_args = ["--clean"] # Pass '--clean' to include 'DROP TABLE' statements in the DB dump.
          if Zealot::Setting.backup.pg_schema
            pgsql_args << "-n"
            pgsql_args << Zealot::Setting.backup.pg_schema
          end

          spawn('pg_dump', *pgsql_args, config['database'], out: compress_wr)
        end
      compress_wr.close

      success = [compress_pid, dump_pid].all? do |pid|
        Process.waitpid(pid)
        $?.success?
      end

      report_result(success)
      raise Backup::Database::Error, 'Backup failed' unless success
    end

    def restore
      decompress_rd, decompress_wr = IO.pipe
      decompress_pid = spawn(*%w(gzip -cd), out: decompress_wr, in: db_file_name)
      decompress_wr.close

      restore_pid =
        case config["adapter"]
        when "postgresql" then
          puts_time("Restoring PostgreSQL database #{config['database']} ... ", false)
          pg_env
          spawn('psql', config['database'], in: decompress_rd)
        end
      decompress_rd.close

      success = [decompress_pid, restore_pid].all? do |pid|
        Process.waitpid(pid)
        $?.success?
      end

      report_result(success)
      raise Backup::Database::Error, 'Restore failed' unless success
    end

    private

    def pg_env
      args = {
        'username'  => 'PGUSER',
        'host'      => 'PGHOST',
        'port'      => 'PGPORT',
        'password'  => 'PGPASSWORD',
        # SSL
        'sslmode'         => 'PGSSLMODE',
        'sslkey'          => 'PGSSLKEY',
        'sslcert'         => 'PGSSLCERT',
        'sslrootcert'     => 'PGSSLROOTCERT',
        'sslcrl'          => 'PGSSLCRL',
        'sslcompression'  => 'PGSSLCOMPRESSION'
      }
      args.each { |opt, arg| ENV[arg] = config[opt].to_s if config[opt] }
    end

    def config
      return @config if @config

      config = ERB.new(File.read(Rails.root.join('config', 'database.yml'))).result()
      @config = YAML.load(config)[Rails.env]
    end

    def db_file_name
      @db_file_name ||= File.join(backup_path, 'db', 'database.sql.gz')
    end
  end
end