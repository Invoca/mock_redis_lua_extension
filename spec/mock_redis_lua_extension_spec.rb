require 'spec_helper'
require 'mock_redis_lua_extension'
require 'mock_redis'

RSpec.describe MockRedisExtension, '' do
  context 'extends a MockRedis instance' do
    before do
      @redis = MockRedisExtension.wrap(MockRedis.new)
    end

    it 'supports eval with keys' do
      result = @redis.eval('return KEYS[1]', keys: ['first_key', 'second_key'])
      expect(result).to eq('first_key')
    end

    it 'supports eval with argv' do
      result = @redis.eval('return ARGV[1]', argv: ['first', 'second'])
      expect(result).to eq('first')
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
