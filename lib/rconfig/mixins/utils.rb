module Mixins
  module Utils

    ##
    # Helper method for white-box testing and debugging.
    # Sets the flag indicating whether or not to log
    # errors and application run-time information.
    def self.log_level=(level)
      logger.level = level unless level.nil?
    end

    def self.log_level
      logger.level
    end

    ##
    # Helper method for white-box testing and debugging.
    # Sets a hash of each file that has been loaded.
    def self.config_file_loaded=(loaded)
      @@config_file_loaded = loaded
    end


    ##
    # Helper method for white-box testing and debugging.
    # Returns a hash of each file that has been loaded.
    def self.config_file_loaded
      @@config_file_loaded
    end

    ##
    # Creates a dottable hash for all Hash objects, recursively.
    def self.create_dottable_hash(hash)
      make_indifferent(hash)
    end
    
    protected

    ##
    # Parses file based on file type.
    # 
    def self.parse_file(conf_file, ext)
      hash = case ext
        when * YML_FILE_TYPES
          YAML::load(conf_file)
        when * XML_FILE_TYPES
          Hash.from_xml(conf_file)
        when * CNF_FILE_TYPES
          PropertiesFileParser.parse(conf_file)
        else
          raise ConfigError, "Unknown File type:#{ext}"
      end
      hash.freeze
    end

    ##
    # Returns a merge of hashes.
    #
    def self.merge_hashes(hashes)
      hashes.inject({}) { |n, h| n.weave(h, true) }
    end


    ## 
    # Recursively makes hashes into frozen IndifferentAccess ConfigFakerHash
    # Arrays are also traversed and frozen.
    #
    def self.make_indifferent(hash)
      case hash
        when Hash
          unless hash.frozen?
            hash.each_pair do |k, v|
              hash[k] = make_indifferent(v)
            end
            hash = ConfigHash.new.merge!(hash).freeze
          end
          logger.debug "make_indefferent: x = #{hash.inspect}:#{hash.class}"
        when Array
          unless hash.frozen?
            hash.collect! do |v|
              make_indifferent(v)
            end
            hash.freeze
          end
        # Freeze Strings.
        when String
          hash.freeze
      end
      hash
    end


    ##
    # If a config file name is specified, flushes cached config values
    # for specified config file. Otherwise, flushes all cached config data.
    # The latter should be avoided in production environments, if possible.
    def self.flush_cache(name=nil)
      if name
        name = name.to_s
        @@cache_hash[name] = nil if @@cache_hash[name]
      else
        logger.warn "Flushing complete config data cache."
        @@suffixes = {}
        @@cache = {}
        @@cache_files = {}
        @@cache_hash = {}
        @@last_auto_check = {}
        self
      end
    end

    ##
    # Get complete file name, including file path for the given config name
    # and directory.
    def self.filename_for_name(name, dir=config_paths[0], ext=:yml)
      File.join(dir, "#{name}.#{ext}")
    end

  end
end
