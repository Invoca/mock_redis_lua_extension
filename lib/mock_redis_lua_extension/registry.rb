require 'singleton'

module MockRedisLuaExtension
  class Registry
    include Singleton

    attr_reader :scripts

    def initialize
      @scripts = {}
    end
  end
end
