require 'spec_helper'
require 'mock_redis_lua_extension'
require 'mock_redis'
require 'pry'

RSpec.describe MockRedisLuaExtension, '' do
  context 'extends a MockRedis instance' do
    before do
      @redis = MockRedisLuaExtension.wrap(MockRedis.new)
    end

    it 'should add a method indicating that the MockRedis has been extended' do
      expect(@redis.respond_to?(:mock_redis_lua_extension_enabled)).to eq(true)
    end

    it 'should raise an ArgumentError when attempting to wrap an object that is not a MockRedis' do
      expect { MockRedisLuaExtension.wrap(Object.new) }.to raise_error(ArgumentError,
                                                                       'Can only wrap MockRedis instances')
    end

    it 'supports eval with keys' do
      result = @redis.eval('return KEYS[1]', keys: ['first_key', 'second_key'])
      expect(result).to eq('first_key')

      result = @redis.eval('return KEYS[2]', ['first_key', 'second_key'])
      expect(result).to eq('second_key')
    end

    it 'supports eval with argv' do
      result = @redis.eval('return ARGV[1]', argv: ['first', 'second'])
      expect(result).to eq('first')

      result = @redis.eval('return ARGV[2]', [], ['first', 'second'])
      expect(result).to eq('second')
    end

    it 'should convert keys and argv to lists of strings' do
      result = @redis.eval('return ARGV[2]', argv: [nil, 2.4])
      expect(result).to eq('2.4')

      result = @redis.eval('return KEYS[1]', keys: [:stuff])
      expect(result).to eq('stuff')
    end

    it 'supports eval with redis bound to self' do
      @redis.hset('myhash', 'field', '5')
      lua_script = %q|
            redis.call('hincrby', KEYS[1], ARGV[1], ARGV[2])
            return true
          |.strip
      result = @redis.eval(lua_script, keys: ['myhash'], argv: ['field', '2'])
      value = @redis.hget('myhash', 'field')
      expect(result).to eq(true)
      expect(value).to eq('7')
    end
  end
end
