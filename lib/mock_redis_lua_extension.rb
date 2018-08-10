begin
  require 'rufus-lua'
  RUFUS_LUA_LOADED = true
rescue StandardError => ex
  RUFUS_LUA_LOADED = false
  STDERR.puts "Failed to load rufus-lua: Exception was #{ex.inspect}"
end

require 'json'
require 'digest'

module MockRedisLuaExtension
  class InvalidCommand < StandardError; end
  class InvalidDataType < StandardError; end

  def self.wrap(instance)
    if !instance.respond_to?(:mock_redis_lua_extension_enabled) && is_a_mock?(instance)
      class << instance
        if RUFUS_LUA_LOADED
          prepend(MockRedisLuaExtension)
        end
      end
    elsif !is_a_mock?(instance)
      raise ArgumentError, 'Can only wrap MockRedis instances'
    end
    instance
  end

  def self.is_a_mock?(instance)
    instance.class.ancestors.any? { |a| a.to_s == 'MockRedis' }
  end

  def mock_redis_lua_extension_enabled
    RUFUS_LUA_LOADED
  end

  def script(subcmd, *args)
    case subcmd.downcase.to_sym
    when :load
      args.count == 1 or raise ArgumentError, "Invalid args: #{args.inspect}"
      script = args.first
      Digest::SHA256.hexdigest(script).tap do |sha|
        script_catalog[sha] = script
      end
    when :flush
      @script_catalog = {}
      true
    when :exists
      args = args.first
      if args.is_a?(Array)
        args.map { |sha| script_catalog.include?(sha) }
      else
        script_catalog.include?(args)
      end
    else
      raise ArgumentError, "Invalid script command: #{subcmd}"
    end
  end

  def evalsha(sha, keys=nil, argv=nil, **args)
    if script(:exists, sha)
      eval(script_catalog[sha], keys, argv, **args)
    else
      raise ArgumentError, "NOSCRIPT No matching script. Please use EVAL."
    end
  end

  def eval(script, keys=nil, argv=nil, **args)
    lua_state = Rufus::Lua::State.new
    setup_keys_and_argv(lua_state, keys, argv, args)

    lua_state.function 'redis.call' do |cmd, *args|
      lua_bound_redis_call(cmd, *args)
    end

    lua_state.function 'cjson.decode' do |arg|
      lua_bound_cjson_decode(arg)
    end

    lua_state.function 'cjson.encode' do |arg|
      lua_bound_cjson_encode(arg)
    end
    marshal_lua_return_to_ruby(lua_state.eval(script))
  end

  private

  def script_catalog
    @script_catalog ||= {}
  end

  def lua_bound_redis_call(cmd, *args)
    cmd = cmd.downcase
    if valid_lua_bound_cmds.include?(cmd.to_sym)
      redis_call_from_lua(cmd, *args)
    else
      raise InvalidCommand, "Invalid command (cmd: #{cmd}, args: #{args.inspect})"
    end
  rescue InvalidDataType => ex
    raise InvalidCommand, "Invalid command (cmd: #{cmd}, args: #{args.inspect}) caused by #{ex.class}(#{ex.message})"
  end

  def lua_bound_cjson_decode(arg)
    JSON.parse(arg)
  end

  def lua_bound_cjson_encode(arg)
    case arg
    when String, Float, Integer, NilClass
      arg.to_json
    when Rufus::Lua::Table
      table_to_array_or_hash(arg).to_json
    else
      raise InvalidDataType, "Unexpected data type for cjson.encode: #{arg.inspect}"
    end
  end

  def setup_keys_and_argv(lua_state, keys, argv, args)
    keys = [] unless keys
    keys = args[:keys] if args[:keys]

    argv = [] unless argv
    argv = args[:argv] if args[:argv]

    lua_state['KEYS'] = keys.map { |k| k.to_s }
    lua_state['ARGV'] = argv.map { |a| a.to_s }
  end

  def redis_call_from_lua(cmd, *args)
    redis_args = marshal_lua_args_to_redis(cmd, args)
    redis_result = self.send(cmd, *redis_args)
    marshal_redis_result_to_lua(redis_result)
  end

  def marshal_lua_args_to_redis(cmd, args)
    options, args = parse_options(cmd, args)
    converted_args = args.map do |arg|
      case arg
      when Float, Integer
        arg.to_s
      when String
        arg
      else
        raise InvalidDataType, "Lua redis() command arguments must be strings or numbers (was: #{args.inspect})"
      end
    end
    if options.any? { |_, v| v }
      converted_args + [options]
    else
      converted_args
    end
  end

  def parse_options(cmd, args)
    limit_cmds = [
      'zrangebyscore',
      'zrangebylex',
      'zrevrangebyscore',
      'zrevrangebylex'
    ]

    scores_cmds = [
      'zrange',
      'zrangebyscore',
      'zrevrangebyscore'
    ]

    limit, args = if args[-3].to_s.downcase == 'limit' && limit_cmds.include?(cmd)
             [args[-2..-1], args[0...-3]]
           else
             [nil, args]
           end

    withscores, args = if args[-1].to_s.downcase == 'withscores' && scores_cmds.include?(cmd)
                         [true, args[0...-1]]
                       else
                         [nil, args]
                       end

    return { limit: limit, with_scores: withscores }, args
  end

  def marshal_redis_result_to_lua(result)
    case result
    when nil
      false
    when true
      1
    when false
      0
    when Integer, String, Array
      result
    when Float
      result.to_s
    else
      raise InvalidDataType, "Unsupported type returned from redis (was: #{result.inspect})"
    end
  end

  def marshal_lua_return_to_ruby(arg)
    case arg
    when false
      nil
    when true
      1
    when Float, Integer
      arg.to_i
    when String, Array, nil
      arg
    when Rufus::Lua::Table
      table_to_array_or_status(arg)
    else
      raise InvalidDataType, "Unsupported type returned from script (was: #{arg.inspect})"
    end
  end

  def table_to_array_or_status(table)
    (1..table.keys.length).map do |i|
      marshal_lua_return_to_ruby(table[i.to_f])
    end.compact
  end

  def table_to_array_or_hash(table)
    if table.keys.all? { |k| k.is_a?(Numeric) && k >=0 }
      table.to_a
    else
      table.to_h
    end
  end

  def valid_lua_bound_cmds
    @valid_lua_bound_cmds ||= Hash[[
        #Hash commands
        :hdel, :hexists, :hget, :hgetall, :hincrby, :hincrbyfloat, :hkeys, :hlen,
        :hmget, :hmset, :hset, :hsetnx, :hstrlen, :hvals, :hscan,

        #Key commands
        :del, :dump, :exists, :expire, :expireat, :keys, :persist, :pexpire, :pexpireat,
        :pttl, :randomkey, :rename, :renamenx, :sort, :touch, :ttl, :type, :unlink,

        #List commands
        :blpop, :brpop, :brpoplpush, :lindex, :linsert, :llen, :lpop, :lpush, :lpushx,
        :lrange, :lrem, :lset, :ltrim, :rpop, :rpoplpush, :rpush, :rpushx,

        #Set commands
        :sadd, :scard, :sdiff, :sdiffstore, :sinter, :sinterstore, :sismember, :smembers,
        :smove, :spop, :srandmember, :srem, :sunion, :sunionstore, :sscan,

        #SortedSet commands
        :zadd, :zcard, :zcount, :zincrby, :zinterstore, :zlexcount, :zrange, :zrangebylex,
        :zrevrangebylex, :zrangebyscore, :zrank, :zrem, :zremrangebylex, :zremrangebyrank,
        :zremrangebyscore, :zrevrange, :zrevrangebyscore, :zrevrank, :zscore, :zunionstore,
        :zscan,

        #String commands
        :append, :bitcount, :bitfield, :bitop, :bitpos, :decr, :decrby, :get, :getbit,
        :getrange, :getset, :incr, :incrby, :incrbyfloat, :mget, :mset, :msetnx, :psetex,
        :set, :setbit, :setex, :setnx, :setrange, :strlen
    ].map {|cmd| [cmd, true] }]
  end
end
