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

      it 'should raise an error if args are not strings or numbers' do
        lua_script = %q|
          redis.call('set', 'foo', {'a', 'b', 'c'})
        |.strip
        expect { redis.eval(lua_script) }.to raise_error(MockRedisLuaExtension::InvalidCommand) do |ex|
          expect(ex.message).to match('caused by MockRedisLuaExtension::InvalidDataType')
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
        expect(@redis.eval(lua_script)).to eq(['bar', 4])
      end

      it 'should encode hash-style tables' do
        lua_script = %q|
          return cjson.encode({ foo='bar', baz=4, null_value=nil })
        |.strip
        expect(@redis.eval(lua_script)).to eq('{"baz":4.0,"foo":"bar"}')
      end

      it 'should encode array-style tables' do
        lua_script = %q|
          return cjson.encode({ 'bar', 4, nil })
        |.strip
        expect(@redis.eval(lua_script)).to eq('["bar",4.0]')
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

      # BUG - MockRedis erronously returns true for redis.hset('myhash', 'existing_key', 'second')
      # TODO - Uncomment this once MockRedis is fixed
      # it 'should convert true to 1 and false to 0' do
      #   expect(redis.hset('myhash', 'existing_key', 'first')).to eq(true)
      #   expect(redis.hset('myhash', 'existing_key', 'second')).to eq(false)
      #   lua_script = %q|
      #     local value = redis.call('hset', 'myhash', 'new_key', 'value')
      #     if value == 1 then
      #       redis.call('set', 'true_value', 'was 1')
      #     else
      #       redis.call('set', 'true_value', 'was not 1')
      #     end
      #
      #     value = redis.call('hset', 'myhash', 'existing_key', 'third')
      #     if value == 0 then
      #       redis.call('set', 'false_value', 'was 0')
      #     else
      #       redis.call('set', 'false_value', 'was not 0')
      #     end
      #   |.strip
      #   redis.eval(lua_script)
      #   expect(redis.get('true_value')).to eq(1)
      #   expect(redis.get('false_value')).to eq(0)
      # end
    end

    describe 'script' do
      context 'passing load subcommand' do
        let(:script) { 'return 1' }
        let(:script_sha) { Digest::SHA1.hexdigest(script) }

        it 'returns sha of script and stores it in registry' do
          sha = redis.script(:load, script)
          expect(sha).to be == script_sha
          loaded_script = described_class::Registry.instance.scripts[script_sha]
          expect(loaded_script).to be == script
        end
      end

      context 'passing not supported subcommand' do
        it 'raises InvalidCommand exception' do
          expect { redis.script(:not_existin_subcommand) }
            .to raise_error described_class::InvalidCommand
        end
      end
    end

    describe 'evalsha' do
      let(:script) do
        <<-LUA
        local value = redis.call('get', KEYS[1])
        if value ~= nil then
          redis.call('del', KEYS[1])
          return value
        else
          return nil
        end
        LUA
      end
      let(:sha) { redis.script(:load, script) }

      before { redis.set('key', 'secret') }

      it 'executes script and returns expected value' do
        expect(redis.evalsha(sha, keys: ['key'])).to be == 'secret'
        expect(redis.exists('key')).to be == false
      end
    end
  end
end
