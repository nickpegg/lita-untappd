Gem::Specification.new do |spec|
  spec.name          = 'lita-untappd'
  spec.version       = '0.0.1'
  spec.authors       = ['Nick Pegg']
  spec.email         = ['code@nickpegg.com']
  spec.description   = 'Untappd handler for Lita'
  spec.summary       = 'Untappd handler for Lita. Pretty minimal so far.'
  spec.homepage      = 'https://github.com/nickpegg/lita-untappd'
  spec.license       = 'MIT'
  spec.metadata      = { 'lita_plugin_type' => 'handler' }

  spec.files         = `git ls-files`.split($RS)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']

  spec.add_runtime_dependency 'lita', '~> 4.0'
  spec.add_runtime_dependency 'redis-objects', '~> 1.2', '>= 1.2.1'
  spec.add_runtime_dependency 'untappd', '~> 4.0'

  spec.add_development_dependency 'bundler', '~> 1.3'
  spec.add_development_dependency 'pry-rescue', '~> 1.4', '>= 1.4.2'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rspec', '>= 3.0.0'
  spec.add_development_dependency 'rubocop', '>= 0.49.0'
end
