module MockRedisLuaExtension
  module Methods
    class Evalsha
      attr_reader :mock_redis

      def initialize(mock_redis)
        @mock_redis = mock_redis
      end

      def call(sha, *args)
        script = Registry.instance.scripts[sha]
        keys = keys(args)
        argv = argv(args)
        mock_redis.eval(script, keys, argv)
      end

      private

      def keys(args)
        return args.last[:keys] if args.last.is_a? Hash
        args.first
      end

      def argv(args)
        return args.last[:argv] if args.last.is_a? Hash
        args[1]
      end
    end
  end
end
