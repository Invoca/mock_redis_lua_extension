# CHANGELOG for `mock_redis_lua_extension`

Inspired by [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

Note: this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0]
### Fixed
- Lua Numbers without decimals will now be converted to integer strings.

### Added
- Added `PUBLISH` to allowable function calls. 
