require 'msgpack'
require 'benchmark/ips'

puts RUBY_VERSION

Benchmark.ips do |x|
  x.report("cached") { MessagePack::Factory.cached_rb_intern }
  x.report("raw") { MessagePack::Factory.raw_rb_intern }
  x.compare!
end
