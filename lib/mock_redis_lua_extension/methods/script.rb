require 'set'
require 'digest'

module MockRedisLuaExtension
  module Methods
    class Script
      SUBCOMMANDS = Set[:load]

      def call(subcommand, *args)
        subcommand = subcommand.to_s.downcase.to_sym
        unless SUBCOMMANDS.include?(subcommand)
          raise InvalidCommand, 'Script method subcommand #{subcommand} '\
                                'is not supported yet'
        end

        send(subcommand, args)
      end

      private

      def load(args)
        script = args.first
        sha = Digest::SHA1.hexdigest(script)
        Registry.instance.scripts[sha] = script
        sha
      end
    end
  end
end
