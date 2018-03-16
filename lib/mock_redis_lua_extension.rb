require 'rufus-lua'

module MockRedisLuaExtension
  class InvalidCommand < StandardError; end

  def self.wrap(instance)
    if !instance.respond_to?(:mock_redis_lua_extension_enabled) && is_a_mock?(instance)
      class << instance
        prepend(MockRedisLuaExtension)
      end
    elsif !is_a_mock?(instance)
      raise ArgumentError, 'Can only wrap MockRedis instances'
    end
    instance
  end

  def self.is_a_mock?(instance)
    instance.class.ancestors.any? { |a| a.to_s == "MockRedis" }
  end

  def mock_redis_lua_extension_enabled
    true
  end

  def eval(script, keys: nil, argv: nil)
    lua_state = Rufus::Lua::State.new
    setup_keys_and_argv(lua_state, keys, argv)

    lua_state.function 'redis.call' do |cmd, *args|
      lua_bound_redis_call(cmd, *args)
    end
    lua_state.eval(script)
  end

  private

  def lua_bound_redis_call(cmd, *args)
    cmd = cmd.downcase
    if valid_lua_bound_cmds.include?(cmd.to_sym)
      exec_redis_cmd(cmd, *args)
    else
      raise InvalidCommand, "Invalid command (cmd: #{cmd}, args: #{args.inspect})"
    end
  end

  def setup_keys_and_argv(lua_state, keys, argv)
    keys = [] unless keys
    argv = [] unless argv
    keys.all? { |k| k.is_a?(String) } or raise ArgumentError, "Keys must be strings (was #{keys.inspect})"
    argv.all? { |a| a.is_a?(String) || a.is_a?(Integer) } or raise ArgumentError, "Argv values must be strings (was #{argv.inspect}"

    lua_state['KEYS'] = keys
    lua_state['ARGV'] = argv.map { |a| a.to_s }
  end

  def exec_redis_cmd(cmd, *args)
    redis_args = marshal_lua_args_to_redis(args)
    redis_result = self.send(cmd, *redis_args)
    marshal_redis_result_to_lua(redis_result)
  end

  def marshal_lua_args_to_redis(args)
    args.map do |arg|
      case arg
        when Float, Integer
          arg.to_i.to_s
        when true
          '1'
        when false
          nil
        else
          arg
      end
    end
  end

  def marshal_redis_result_to_lua(arg)
    case arg
      when nil
        false
      when Integer
        arg.to_s
      else
        arg
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
