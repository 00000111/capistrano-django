Gem::Specification.new do |s|

  s.name     = "capistrano-django"
  s.version  = "3.5.3"

  s.homepage = "http://github.com/mattjmorrison/capistrano-django"
  s.summary  = %q{capistrano-django - Welcome to easy deployment with Ruby over SSH for Django}
  s.description = %q{capistrano-django provides a solid basis for common django deployment}

  s.files         = `git ls-files`.split($/)
  s.require_paths = ["lib"]

  s.required_ruby_version = '>= 1.9.3'
  s.add_dependency "capistrano", "~> 3.4.0"
  s.add_dependency "aws-sdk", "~> 2"

  s.author   = "Matthew J. Morrison"
  s.email    = "mattjmorrison@mattjmorrison.com"

end
