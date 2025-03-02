require 'spec_helper'
require 'mock_redis_lua_extension'
require 'mock_redis'

require 'pry'

RSpec.describe MockRedisLuaExtension, '::' do

  let(:redis) { MockRedisLuaExtension.wrap(MockRedis.new) }

  context 'extending a MockRedis instance' do
    it 'should add a method indicating that the MockRedis has been extended' do
      expect(redis.respond_to?(:mock_redis_lua_extension_enabled)).to eq(true)
    end

    it 'should raise an ArgumentError when attempting to wrap an object that is not a MockRedis' do
      expect { MockRedisLuaExtension.wrap(Object.new) }.to raise_error(ArgumentError,
                                                                       'Can only wrap MockRedis instances')
    end

    it 'supports eval with redis bound to self' do
      redis.hset('myhash', 'field', 5)
      lua_script = %q|
            redis.call('hincrby', KEYS[1], ARGV[1], ARGV[2])
      |.strip
      redis.eval(lua_script, keys: ['myhash'], argv: ['field', 2])
      value = redis.hget('myhash', 'field')
      expect(value).to eq('7')
    end

    it 'supports the script command to load scripts for use with evalsha' do
      sha = redis.script(:load, 'return "EXECUTED"')
      expect(redis.evalsha(sha)).to eq('EXECUTED')
    end

    it 'supports script exists' do
      sha = redis.script(:load, 'return "EXECUTED"')
      expect(redis.script(:exists, sha)).to eq(true)

      expect(redis.script(:exists, '1114444')).to eq(false)
    end

    it 'supports script exists with multiple shas' do
      sha1 = redis.script(:load, 'return "EXECUTED"')
      sha2 = redis.script(:load, 'return "DIFFERENT"')
      expect(redis.script(:exists, [sha1, sha2, 'invalidsha'])).to eq([true, true, false])
    end

    it 'supports evalsha' do
      sha = redis.script(:load, 'return { KEYS[1], ARGV[1] }')
      expect(redis.evalsha(sha, ['key1', 'key2'], ['arg1', 'arg2'])).to eq(['key1', 'arg1'])
    end

    context 'eval arguments' do
      it 'passes keys as KEYS table' do
        result = redis.eval('return KEYS[1]', keys: ['first_key', 'second_key'])
        expect(result).to eq('first_key')

        result = redis.eval('return KEYS[2]', ['first_key', 'second_key'])
        expect(result).to eq('second_key')
      end

      it 'passes argv as ARGV table' do
        result = redis.eval('return ARGV[1]', argv: ['first', 'second'])
        expect(result).to eq('first')

        result = redis.eval('return ARGV[2]', [], ['first', 'second'])
        expect(result).to eq('second')
      end

      it 'should convert keys and argv to lists of strings' do
        result = redis.eval('return ARGV[2]', argv: [nil, 2.4])
        expect(result).to eq('2.4')

        result = redis.eval('return KEYS[1]', keys: [:stuff])
        expect(result).to eq('stuff')
      end
    end

    context 'marshalling lua args to redis.call' do
      it 'should convert lua numbers to strings' do
        redis.eval(%q| redis.call('set', 'foo', 1.5) |)
        expect(redis.get('foo')).to eq('1.5')
      end

      it 'converts lua numbers with decimals that are integers to integer strings' do
        redis.eval(%q| redis.call('set', 'foo', 1.0) |)
        expect(redis.get('foo')).to eq('1')
      end

      it "should not convert lua numbers without decimals to floats" do
        redis.eval(%q| redis.call('set', 'foo', 1) |)
        expect(redis.get('foo')).to eq('1')
      end

      it 'should raise an error if args are not strings or numbers' do
        lua_script = %q|
          redis.call('set', 'foo', {'a', 'b', 'c'})
        |.strip
        expect { redis.eval(lua_script) }.to raise_error(MockRedisLuaExtension::InvalidCommand) do |ex|
          expect(ex.message).to match('caused by MockRedisLuaExtension::InvalidDataType')
        end
      end

      context 'hash options' do
        before do
          redis.zadd('foo', 1, 'washington')
          redis.zadd('foo', 2, 'jefferson')
          redis.zadd('foo', 3, 'adams')
          redis.zadd('foo', 4, 'madison')
        end

        it 'should convert limits into a hash option' do
          lua_script = %q|
           return redis.call('ZRANGEBYSCORE', 'foo', 2, 4, 'LIMIT', 0, 2)
          |.strip
          expect(redis.eval(lua_script)).to eq(['jefferson', 'adams'])
        end

        it 'should convert withscores into a hash option' do
          lua_script = %q|
           return redis.call('ZRANGEBYSCORE', 'foo', 2, 3, 'WITHSCORES')
          |.strip
          expected_result = ['jefferson', 2.0, 'adams', 3.0]
          expect(redis.eval(lua_script)).to eq(expected_result)
        end

        it 'should support both hash options' do
          lua_script = %q|
           return redis.call('ZRANGEBYSCORE', 'foo', 2, 4, 'WITHSCORES', 'LIMIT', 1, 2)
          |.strip
          expected_result = ['adams', 3.0, 'madison', 4.0]
          expect(redis.eval(lua_script)).to eq(expected_result)
        end
      end
    end

    context 'marshalling lua return values to ruby' do
      it 'should convert true to 1' do
        expect(redis.eval(%q| return true |)).to eq(1)
      end

      it 'should convert false to nil' do
        expect(redis.eval(%q| return false |)).to eq(nil)
      end

      it 'should convert numbers to integers' do
        expect(redis.eval(%q| return 2.3 |)).to eq(2)
      end

      it 'should leave strings as is' do
        expect(redis.eval(%q| return 'a simple string'|)).to eq('a simple string')
      end

      it 'should convert tables to arrays (ignoring keys)' do
        expect(redis.eval(%q| return {foo='bar', 'a', 'b', 'c'} |)).to eq(['a', 'b', 'c'])
      end

      it 'should return redis success responses as "OK"' do
        lua_script = %q|
          return redis.call('set', 'foo', 'bar')
        |.strip
        expect(redis.eval(lua_script)).to eq('OK')
      end

      it 'should correctly marshall nested tables' do
        expect(redis.eval(%q| return {foo='bar', 'a', 1.4, {'b', 2.7}} |)).to eq(['a', 1, ['b', 2]])
      end
    end

    context 'cjson implementation' do
      it 'should decode json strings' do
        lua_script = %q|
         local result = cjson.decode('{"foo":"bar","baz":4,"nil_value":null}')
         return { result.foo, result.baz, result.nil_value }
        |.strip
        expect(redis.eval(lua_script)).to eq(['bar', 4])
      end

      it 'should encode hash-style tables' do
        lua_script = %q|
          return cjson.encode({ foo='bar', baz=4, null_value=nil })
        |.strip
        expect(redis.eval(lua_script)).to eq('{"baz":4.0,"foo":"bar"}')
      end

      it 'should encode array-style tables' do
        lua_script = %q|
          return cjson.encode({ 'bar', 4, nil })
        |.strip
        expect(redis.eval(lua_script)).to eq('["bar",4.0]')
      end

      it 'should encode strings' do
        lua_script = %q|
          return cjson.encode('in_service')
        |.strip
        expect(redis.eval(lua_script)).to eq('"in_service"')
      end

      it 'should encode nil' do
        lua_script = %q|
          return cjson.encode(nil)
        |.strip
        expect(redis.eval(lua_script)).to eq('null')
      end

      it 'should encode numbers' do
        lua_script = %q|
          return cjson.encode(4)
        |.strip
        expect(redis.eval(lua_script)).to eq('4.0')
      end

      it 'should encode floats' do
        lua_script = %q|
          return cjson.encode(4.2)
        |.strip
        expect(redis.eval(lua_script)).to eq('4.2')
      end
    end

    context 'marshalling redis.call return values to lua' do
      it 'should convert nil to false' do
        lua_script = %q|
          local value = redis.call('get', 'not_defined')
          if value == nil then
            redis.call('set', 'value', 'was nil')
          elseif value == false then
            redis.call('set', 'value', 'was false')
          end
        |.strip
        redis.eval(lua_script)
        expect(redis.get('not_defined')).to eq(nil)
        expect(redis.get('value')).to eq('was false')
      end

      it 'should marshall arrays into tables' do
        redis.zadd('myset', 1, 'one')
        redis.zadd('myset', 2, 'two')
        redis.zadd('myset', 3, 'three')
        lua_script = %q|
           local result = redis.call('zrangebyscore', 'myset', 2, 3)
           return { result[1], result[2] }
        |.strip
        expect(redis.eval(lua_script)).to eq(['two', 'three'])
      end

      it 'should leave strings and numbers as is' do
        redis.lpush('string_value', 'value')
        lua_script = %q|
          local value = redis.call('lindex', 'string_value', 0)
          if value == 'value' then
            redis.call('set', 'string_result', 'was unchanged')
          else
            redis.call('set', 'string_result', 'was changed')
          end

          value = redis.call('llen', 'string_value')
          if value == 1 then
            redis.call('set', 'number_result', 'was unchanged')
          else
            redis.call('set', 'number_result', 'was changed')
          end
        |.strip
        redis.eval(lua_script)
        expect(redis.get('string_result')).to eq('was unchanged')
        expect(redis.get('number_result')).to eq('was unchanged')
      end

      it 'should return scores as strings' do
        redis.zadd('myset', 1, 'one')
        redis.zadd('myset', 2, 'two')
        redis.zadd('myset', 3, 'three')
        lua_script = %q|
          local result = redis.call('zscore', 'myset', 'two')
          return result
        |.strip

        expect(redis.eval(lua_script)).to eq('2.0')
      end
    end

    context "redis.breakpoint" do
      it 'calls binding.pry when redis.breakpoint() is called' do
        expect_any_instance_of(Binding).to receive(:pry)
        redis.eval("redis.breakpoint()")
      end

      it 'puts parsed args when redis.debug() is called' do
        hash = { "monkey" => "banana", "number" => 200.0 }
        expect_any_instance_of(MockRedis).to receive(:puts).with("hello, hi, 1.0, [5.0, 10.0], #{hash}, goodbye")
        lua_script = %q|
          local var1 = "hi"
          local var2 = 1.0

          local my_array = {}
          table.insert(my_array, 5)
          table.insert(my_array, 10)

          local my_hash = {}
          my_hash["monkey"] = "banana"
          my_hash["number"] = 200

          redis.debug("hello", var1, var2, my_array, my_hash, "goodbye")
        |.strip
        redis.eval(lua_script)
      end
    end
  end
end
