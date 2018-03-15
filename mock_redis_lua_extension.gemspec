$LOAD_PATH.push File.expand_path("../lib", __FILE__)

require "mock_redis_lua_extension/version"

# Describe your gem and declare its dependencies:
Gem::Specification.new do |s|
  s.name        = "mock_redis_lua_extension"
  s.version     = MockRedisLuaExtension::VERSION
  s.authors     = ["Chad Simmons"]
  s.email       = ["csimmons@invoca.com"]
  s.homepage    = "https://github.com/Invoca/mock_redis_lua_extension"
  s.summary     = "Extension to mock_redis enabling lua execution via rufus-lua"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- spec/*`.split("\n")
  s.require_paths = ['lib']

  s.add_dependency 'mock_redis'
  s.add_dependency 'rufus-lua'
  s.add_development_dependency 'rake', '>= 10', '< 12'
  s.add_development_dependency 'rspec', '~> 3.0'
end
