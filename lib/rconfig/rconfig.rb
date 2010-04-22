##
#
# Copyright (c) 2009 Rahmal Conda <rahmal@gmail.com>
# -------------------------------------------------------------------
# The complete solution for Ruby Configuration Management. RConfig is a Ruby library that 
# manages configuration within Ruby applications. It bridges the gap between yaml, xml, and 
# key/value based properties files, by providing a centralized solution to handle application 
# configuration from one location. It provides the simplicity of hash-based access, that 
# Rubyists have come to know and love, supporting your configuration style of choice, while 
# providing many new features, and an elegant API.
#
# -------------------------------------------------------------------
# * Simple, easy to install and use.
# * Supports yaml, xml, and properties files.
# * Yaml and xml files supprt infinite level of configuration grouping.
# * Intuitive dot-notation 'key chaining' argument access.
# * Simple well-known hash/array based argument access.
# * Implements multilevel caching to reduce disk access.
# * Short-hand access to 'global' application configuration, and shell environment.
# * Overlays multiple configuration files to support environment, host, and 
#   even locale-specific configuration.
#
# -------------------------------------------------------------------
#  The overlay order of the config files is defined by SUFFIXES:
#  * nil
#  * _local
#  * _config
#  * _local_config
#  * _{environment} (.i.e _development)
#  * _{environment}_local (.i.e _development_local)
#  * _{hostname} (.i.e _whiskey)
#  * _{hostname}_config_local (.i.e _whiskey_config_local)
#
# -------------------------------------------------------------------
#
# Example:
#
#  shell/console =>
#    export LANG=en
#
#  demo.yml =>
#   server:
#     address: host.domain.com
#     port: 81
#  ...
#
#  application.properties =>
#    debug_level = verbose
#  ...
#
# demo.rb => 
#  require 'rconfig'
#  RConfig.config_paths = ['$HOME/config', '#{APP_ROOT}/config', '/demo/conf']
#  RConfig.demo[:server][:port] => 81
#  RConfig.demo.server.address  => 'host.domain.com'
#
#  RConfig[:debug_level] => 'verbose'
#  RConfig[:lang] => 'en'
#  ...
#
class RConfig
  include Singleton, 
          Mixins::Constants, Mixins::ClassVariables,
          Mixins::ConfigPaths, Mixins::Overlay
  
  create_logger

  ##
  # Convenience method to initialize necessary fields including,
  # config path(s), overlay, allow_reload, and log_level, all at
  # one time.
  def self.initialize(*args)
    case args[0]
    when Hash
      params  = args[0].symbolize_keys
      paths   = params[:paths]
      overlay = params[:overlay]
      reload  = params[:reload]
      loglvl  = params[:log_level]
    else
      paths, overlay, reload, loglvl = *args
    end
    self.config_paths = paths
    self.overlay      = overlay
    self.allow_reload = reload
    self.log_level    = loglvl
  end
  
  ##
  # Get each config file's yaml hash for the given config name, 
  # to be merged later. Files will only be loaded if they have 
  # not been loaded before or the files have changed within the 
  # last five minutes, or force is explicitly set to true.
  #
  def self.load_config_files(name, force=false)
    name = name.to_s # if name.is_a?(Symbol)

    # Return last config file hash list loaded,
    # if reload is disabled and files have already been loaded.
    return @@cache_config_files[name] if 
      @@reload_disabled && 
      @@cache_config_files[name]

    now = Time.now

    # Get array of all the existing files file the config name.
    config_files = self.get_config_files(name)

    logger.debug "load_config_files(#{name.inspect})" 
    
    # Get all the data from all yaml files into as hashes
    hashes = config_files.collect do |f|
      name, name_x, filename, ext, mtime = *f

      # Get the cached file info the specific file, if 
      # it's been loaded before.
      val, last_mtime, last_loaded = @@cache[filename] 

      logger.debug {
        "f = #{f.inspect}" +
        "cache #{name_x} filename = #{filename.inspect}" +
        "cache #{name_x} val = #{val.inspect}" +
        "cache #{name_x} last_mtime = #{last_mtime.inspect}" +
        "cache #{name_x} last_loaded = #{last_loaded.inspect}"
      }

      # Load the file if its never been loaded or its been more than
      # so many minutes since last load attempt. (default: 5 minutes) 
      if val.blank? || (now - last_loaded > @@reload_interval)
        if force || val.blank? || mtime != last_mtime

          logger.debug "mtime #{name.inspect} #{filename.inspect} " + 
                      "changed #{mtime != last_mtime} : #{mtime.inspect} #{last_mtime.inspect}"
          
          # Get contents from config file
          File.open(filename) do |f|
            logger.debug "RConfig: loading #{filename.inspect}" 
            val = parse_file(f, ext)              
            val = val[name] if ext == :xml # xml document must have root tag matching the file name.
            logger.debug "RConfig: loaded #{filename.inspect} => #{val.inspect}" 
            (@@config_file_loaded ||= { })[name] = config_files
          end
            
          # Save cached config file contents, and mtime.
          @@cache[filename] = [ val, mtime, now ]
          logger.debug "cache[#{filename.inspect}] = #{@@cache[filename].inspect}" 

          # Flush merged hash cache.
          @@cache_hash[name] = nil
                 
          # Config files changed or disappeared.
          @@cache_files[name] = config_files

        end # if val == nil || (now - last_loaded > @@reload_interval)
      end   # if force || val == nil || mtime != last_mtime

      val
    end
    hashes.compact!

    logger.debug "load_config_files(#{name.inspect}) => #{hashes.inspect}"

    # Keep last loaded config files around in case @@reload_dsabled.
    @@cache_config_files[name] = hashes #unless hashes.empty?

    hashes
  end


  ##
  # Parses file based on file type.
  # 
  def self.parse_file(conf_file, ext)
    hash = case ext
    when *YML_FILE_TYPES
      YAML::load(conf_file)
    when *XML_FILE_TYPES
      Hash.from_xml(conf_file)
    when *CNF_FILE_TYPES
      PropertiesFileParser.parse(conf_file)
    else
      raise ConfigError, "Unknown File type:#{ext}"
    end
    hash.freeze
  end


  ## 
  # Returns a list of all relevant config files as specified
  # by _suffixes list.
  # Each element is an Array, containing:
  #   [ "the-top-level-config-name",
  #     "the-suffixed-config-name",
  #     "/the/absolute/path/to/yaml.yml",
  #     # The mtime of the yml file or nil, if it doesn't exist.
  #   ]
  def self.get_config_files(name) 
    files = []

    config_paths.reverse.each do | dir |
      # splatting *suffix allows us to deal with multipart suffixes 
      name_no_overlay, suffixes = suffixes(name)
      suffixes.map { | suffix | [ name_no_overlay, *suffix ].compact.join('_') }.each do | name_x |
        CONFIG_FILE_TYPES.each do |ext|    
          filename = filename_for_name(name_x, dir, ext)
          if File.exists?(filename)
            files << [ name, name_x, filename, ext, File.stat(filename).mtime ]
          end
        end
      end
    end

    logger.debug "get_config_files(#{name}) => #{files.select{|x| x[3]}.inspect}" 

    files
  end


  ##
  # Return the config file information for the given config name.
  #
  def self.config_files(name)
    @@cache_files[name] ||= get_config_files(name)
  end


  ##
  # Returns whether or not the config for the given config name has changed 
  # since it was last loaded.
  #
  # Returns true if any files for config have changes since
  # last load.
  def self.config_changed?(name)
    logger.debug "config_changed?(#{name.inspect})" 
    name = name.to_s # if name.is_a?(Symbol)
    ! (@@cache_files[name] === get_config_files(name))
  end


  ## 
  # Get the merged config hash for the named file.
  # Returns a cached indifferent access faker hash merged
  # from all config files for a name.
  #
  def self.config_hash(name)
    logger.debug "config_hash(#{name.inspect})"

    name = name.to_s
    unless result = @@cache_hash[name]
      result = @@cache_hash[name] = 
        make_indifferent(
          merge_hashes(
            load_config_files(name)
          )
        )
      logger.debug "config_hash(#{name.inspect}): reloaded" 
    end

    result
  end


  ##
  # If config files have changed,
  # Caches are flushed, on_load triggers are run.
  def self.check_config_changed(name = nil)
    changed = []
    if name == nil
      @@cache_hash.keys.dup.each do | name |
        if config_has_changed?(name)
          changed << name
        end
      end
    else
      name = name.to_s #  if name.is_a?(Symbol)
      if config_has_changed?(name)
        changed << name
      end
    end

    logger.debug "check_config_changed(#{name.inspect}) => #{changed.inspect}" 

    changed.empty? ? nil : changed
  end


  def self.config_has_changed?(name)
    logger.debug "config_has_changed?(#{name.inspect}), reload_disabled=#{@@reload_disabled}" 

    changed = false

    if config_changed?(name) && reload?
      if @@cache_hash[name]
        @@cache_hash[name] = nil

        # force on_load triggers.
        fire_on_load(name)
      end

      changed = true
    end

    changed
  end


  ##
  # Returns a merge of hashes.
  #
  def self.merge_hashes(hashes)
    hashes.inject({ }) { | n, h | n.weave(h, true) }
  end


  ## 
  # Recursively makes hashes into frozen IndifferentAccess ConfigFakerHash
  # Arrays are also traversed and frozen.
  #
  def self.make_indifferent(x)
    case x
    when Hash
      unless x.frozen?
        x.each_pair do | k, v |
          x[k] = make_indifferent(v)
        end
        x = ConfigHash.new.merge!(x).freeze
      end
      logger.debug "make_indefferent: x = #{x.inspect}:#{x.class}"
    when Array
      unless x.frozen?
        x.collect! do | v |
          make_indifferent(v)
        end
        x.freeze
      end
    # Freeze Strings.
    when String
      x.freeze
    end

    x
  end


  ##
  # This method provides shorthand to retrieve confiuration data that 
  # is global in scope, and used on an application or environment-wide 
  # level. The default location that it checks is the application file.  
  # The application config file is a special config file that should be 
  # used for config data that is broad in scope and used throughout the 
  # application. Since RConfig gives special regard to the application
  # config file, thought should be given to whatever config information 
  # is placed there.
  #
  # Most config data will be specific to particular part of the
  # application (i.e. database, web service), and should therefore
  # be placed in its own specific config file, such as database.yml,
  # or services.xml
  #
  # This method also acts as a wrapper for ENV. If no value is 
  # returned from the application config, it will also check
  # ENV for a value matching the specified key.
  #
  # Ex.1  RConfig[:test_mode] =>
  #        RConfig.application[:test_mode] || 
  #        RConfig.application.test_mode
  #
  # Ex.2  RConfig[:web_app_root] => ENV['WEB_APP_ROOT']
  #       
  # NOTE: The application config file can be in any of 
  #       the supported formats (yml, xml, conf, etc.)
  #
  def self.[](key, file=:application)
    self.get_config_file(file)[key] || ENV[key.to_s.upcase]
  end


  ##
  # Get the value specified by the args, in the file specified by th name 
  #
  def self.with_file(name, *args)
    # logger.debug "with_file(#{name.inspect}, #{args.inspect})"; result = 
    args.inject(get_config_file(name)) { | v, i | 
      # logger.debug "v = #{v.inspect}, i = #{i.inspect}"
      case v
      when Hash
        v[i.to_s]
      when Array
        i.is_a?(Integer) ? v[i] : nil
      else
        nil
      end
    }
    # logger.debug "with_file(#{name.inspect}, #{args.inspect}) => #{result.inspect}"; result
  end


  ##
  # Get the merged config hash.
  # Will auto check every 5 minutes, for longer running apps.
  #
  def self.get_config_file(name)
    name = name.to_s 
    now = Time.now

    if (! @@last_auto_check[name]) || (now - @@last_auto_check[name]) > @@reload_interval
      @@last_auto_check[name] = now
      check_config_changed(name)
    end

    result = config_hash(name)

    logger.debug "get_config_file(#{name.inspect}) => #{result.inspect}"

    result
  end
  


  ##
  # Creates a dottable hash for all Hash objects, recursively.
  def self.create_dottable_hash(value)
    make_indifferent(value)
  end


  ##
  # Short-hand access to config file by its name.
  #
  # Example:
  #
  #   RConfig.provider(:foo) => RConfig.with_file(:provider).foo
  #   RConfig.provider.foo   => RConfig.with_file(:provider).foo
  #
  def self.method_missing(method, *args)
    value = with_file(method, *args)
    logger.debug "#{self}.method_missing(#{method.inspect}, #{args.inspect}) => #{value.inspect}"
    value
  end


  ##
  # Creating an instance isn't required.  But if you just have to a reference to RConfig
  # you can get it using RConfig.instance.  It's a singleton, so there's never more than
  # one.  The instance has no state, and no methods of it's own accept what it inherits 
  # from object. But this method delegates back to the class, so configuration data is 
  # still accessible.
  #
  # Example:
  #
  #   config = RConfig.instance
  #   config.provider(:foo) => RConfig.provider(:foo)
  #   config.provider.foo   => RConfig.provider.foo
  #
  def method_missing(method, *args)
    self.class.method_missing(method, *args)
  end


  ##
  # Creating an instance isn't required.  But if you just have to a reference to RConfig
  # you can get it using RConfig.instance.  It's a singleton, so there's never more than
  # one.  The instance has no state, and no methods of it's own accept what it inherits 
  # from object. But this method delegates back to the class, so configuration data is 
  # still accessible.
  #
  # Example:
  #
  #   config = RConfig.instance
  #   config[:foo] => RConfig[:foo]
  #
  def [](key)
    self.class[key]
  end


  ##
  # Helper method for white-box testing and debugging.
  # Sets the flag indicating whether or not to log
  # errors and application run-time information.
  def self.log_level=(x)
    logger.level = level unless level.nil?
  end

  def self.log_level
    logger.level
  end

  ##
  # Helper method for white-box testing and debugging.
  # Sets a hash of each file that has been loaded.
  def self.config_file_loaded=(x)
    @@config_file_loaded = x
  end


  ##
  # Helper method for white-box testing and debugging.
  # Returns a hash of each file that has been loaded.
  def self.config_file_loaded
    @@config_file_loaded
  end


protected


  ##
  # Executes all of the reload callbacks registered to the specified config name,
  # and all of the callbacks registered to run on any config, as specified by the
  # :ANY symbol.
  def self.fire_on_load(name)
    callbacks =
      (@@on_load['ANY'] || EMPTY_ARRAY) +
      (@@on_load[name] || EMPTY_ARRAY)
    callbacks.uniq!
    logger.debug "fire_on_load(#{name.inspect}): callbacks[#{callbacks.inspect}]"  unless callbacks.empty?
    callbacks.each{|cb| cb.call()}
  end


  ##
  # Flushes cached config data. This should avoided in production
  # environments, if possible.
  def self.flush_cache
    @@suffixes = { }
    @@cache = { } 
    @@cache_files = { } 
    @@cache_hash = { }
    @@last_auto_check = { }
    self
  end


  ##
  # Get complete file name, including file path for the given config name
  # and directory.
  def self.filename_for_name(name, dir = config_paths[0], ext = :yml)
    File.join(dir, "#{name}.#{ext}")
  end

end # class RConfig
