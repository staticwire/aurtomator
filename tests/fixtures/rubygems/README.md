# rubygems.org fixtures

Answers of rubygems.org read on 2026-11-25. `versions/nokogiri.json` keeps the entries of 1.19.6 and 1.19.7, all platforms; the other files are whole.

- `versions/bashcov.json`: https://rubygems.org/api/v1/versions/bashcov.json
- `versions/nokogiri.json`: https://rubygems.org/api/v1/versions/nokogiri.json
- `versions/simplecov-cobertura.json`: https://rubygems.org/api/v1/versions/simplecov-cobertura.json
- `v2/bashcov-3.3.0.json`: https://rubygems.org/api/v2/rubygems/bashcov/versions/3.3.0.json
- `v2/bashcov-4.0.0.json`: https://rubygems.org/api/v2/rubygems/bashcov/versions/4.0.0.json
- `v2/bashcov-4.0.3.json`: https://rubygems.org/api/v2/rubygems/bashcov/versions/4.0.3.json
- `v2/simplecov-cobertura-4.0.0.json`: https://rubygems.org/api/v2/rubygems/simplecov-cobertura/versions/4.0.0.json
- `v2/json-3.2.0.json`: https://rubygems.org/api/v2/rubygems/json/versions/3.2.0.json?platform=ruby
- `v2/json-3.2.0.no-query.json`: https://rubygems.org/api/v2/rubygems/json/versions/3.2.0.json, which answers the release of platform java

Mock curl answers a request with `?platform=ruby` from `v2/<gem>-<version>.json`, and a request without the query from `v2/<gem>-<version>.no-query.json` where that file exists. bashcov and simplecov-cobertura have one platform, and rubygems.org gives them the same answer with or without the query.
