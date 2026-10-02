require 'spec_helper'

if defined?(Ractor)
  describe "Ractor" do
    # spec_helper enables GC compaction, which hangs Ruby 4.1.0dev when several Ractors are running.
    around do |example|
      auto_compact = GC.respond_to?(:auto_compact) && GC.auto_compact
      GC.auto_compact = false if auto_compact
      begin
        example.run
      ensure
        GC.auto_compact = true if auto_compact
      end
    end

    def ractor_value(ractor)
      ractor.respond_to?(:value) ? ractor.value : ractor.take
    end

    def constant_names(mod, seen = {})
      return [] if seen[mod]
      seen[mod] = true

      mod.constants(false).flat_map do |name|
        value = mod.const_get(name, false)
        names = ["#{mod}::#{name}"]
        names += constant_names(value, seen) if value.is_a?(Module) && value.name.to_s.start_with?("MessagePack")
        names
      end
    end

    it "packs and unpacks in a non-main Ractor" do
      ractor = Ractor.new do
        packer = MessagePack::Packer.new
        packer.write({ "a" => [1, 2.5, nil, true, "x" * 10_000, :sym] })
        unpacker = MessagePack::Unpacker.new(symbolize_keys: true, key_cache: true, freeze: true)
        unpacker.feed(packer.to_s)
        unpacker.read
      end

      expect(ractor_value(ractor)).to eq(a: [1, 2.5, nil, true, "x" * 10_000, "sym"])
    end

    it "packs and unpacks in several Ractors at once" do
      ractors = 4.times.map do |i|
        Ractor.new(i) do |i|
          object = { "ractor" => i, "items" => 100.times.map { |j| ["#{i}-#{j}" * 50, j] } }
          1_000.times.all? do
            unpacker = MessagePack::Unpacker.new
            unpacker.feed(MessagePack::Packer.new.write(object).to_s)
            unpacker.read == object
          end
        end
      end

      expect(ractors.map { |ractor| ractor_value(ractor) }).to eq([true] * 4)
    end

    it "has shareable constants, except DefaultFactory" do
      unshareable = constant_names(MessagePack).reject { |name| Ractor.shareable?(Object.const_get(name)) }
      expect(unshareable).to eq(["MessagePack::DefaultFactory"])
    end

    it "registers MessagePack::Time in a non-main Ractor" do
      ractor = Ractor.new do
        factory = MessagePack::Factory.new
        factory.register_type(-1, Time, packer: MessagePack::Time::Packer, unpacker: MessagePack::Time::Unpacker)
        time = Time.at(1, 2, :nanosecond)
        factory.load(factory.dump(time)) == time
      end

      expect(ractor_value(ractor)).to eq(true)
    end

    describe "a factory made shareable" do
      let :factory do
        factory = MessagePack::Factory.new
        factory.register_type(1, RactorSpec::Point)
        factory.register_type(-1, Time, packer: MessagePack::Time::Packer, unpacker: MessagePack::Time::Unpacker)
        Ractor.make_shareable(factory)
      end

      it "is shareable" do
        expect(Ractor.shareable?(factory)).to eq(true)
      end

      it "packs and unpacks registered types and their subclasses in several Ractors at once" do
        ractors = 4.times.map do |i|
          Ractor.new(factory, i) do |factory, i|
            1_000.times.all? do |j|
              GC.start if j % 100 == 0
              object = [RactorSpec::Point.new(i, j), RactorSpec::SubPoint.new(j, i), Time.at(i, j, :nanosecond)]
              factory.load(factory.dump(object)) == [RactorSpec::Point.new(i, j), RactorSpec::Point.new(j, i), Time.at(i, j, :nanosecond)]
            end
          end
        end

        expect(ractors.map { |ractor| ractor_value(ractor) }).to eq([true] * 4)
      end

      it "creates pools in a non-main Ractor" do
        ractor = Ractor.new(factory) do |factory|
          pool = factory.pool(2)
          pool.load(pool.dump([RactorSpec::SubPoint.new(1, 2)]))
        end

        expect(ractor_value(ractor)).to eq([RactorSpec::Point.new(1, 2)])
      end

      it "packs subclasses with packers created before it was made shareable" do
        factory = MessagePack::Factory.new
        factory.register_type(1, RactorSpec::Point)
        packer = factory.freeze.packer
        Ractor.make_shareable(factory)

        packer.write(RactorSpec::SubPoint.new(1, 2))
        expect(factory.load(packer.to_s)).to eq(RactorSpec::Point.new(1, 2))
        own = hashes(packer).find { |hash| hash.key?(RactorSpec::SubPoint) }
        expect(own).not_to be_nil
        expect(own).not_to be_frozen
        expect(lookup_cache(factory)).to be_empty
      end

      # The lookup cache is the hash, other than the registered types, that remembers which registered type a
      # subclass is packed as.
      def hashes(object)
        ObjectSpace.reachable_objects_from(object).grep(Hash)
      end

      def lookup_cache(factory)
        caches = hashes(factory).reject { |hash| hash.key?(RactorSpec::Point) }
        expect(caches.size).to eq(1)
        caches.first
      end

      it "lets its packers share its frozen lookup cache until they add to it" do
        cache = lookup_cache(factory)
        expect(cache).to be_frozen
        packer = factory.packer
        expect(hashes(packer)).to include(be(cache))

        packer.write(RactorSpec::SubPoint.new(1, 2))
        packer.write(RactorSpec::Point.new(3, 4))
        expect(factory.unpacker.feed(packer.to_s).each.to_a).to eq([RactorSpec::Point.new(1, 2), RactorSpec::Point.new(3, 4)])
        own = hashes(packer).find { |hash| hash.key?(RactorSpec::SubPoint) }
        expect(own).not_to be_frozen
        expect(hashes(packer)).not_to include(be(cache))

        expect(lookup_cache(factory)).to be(cache)
        expect(cache).to be_frozen
        expect(cache).to be_empty
        expect(hashes(factory.packer)).to include(be(cache))
      end

      it "keeps its lookup cache when its packers try to register types" do
        cache = lookup_cache(factory)
        [factory.packer, factory.packer.write(RactorSpec::SubPoint.new(1, 2))].each do |packer|
          expect { packer.register_type(2, RactorSpec::SubPoint) { "sub" } }.to raise_error(FrozenError)
        end
        expect(lookup_cache(factory)).to be(cache)
        expect(cache).to be_frozen
        expect(cache).to be_empty
      end

      it "fills a copy of its lookup cache in each packer in several Ractors at once" do
        ractors = 4.times.map do |i|
          Ractor.new(factory, i) do |factory, i|
            packers = 10.times.map { factory.packer }
            100.times.all? do |j|
              packers.all? do |packer|
                packer.write(RactorSpec::SubPoint.new(i, j))
                loaded = factory.load(packer.to_s)
                packer.clear
                loaded == RactorSpec::Point.new(i, j)
              end
            end
          end
        end

        expect(ractors.map { |ractor| ractor_value(ractor) }).to eq([true] * 4)
        expect(lookup_cache(factory)).to be_frozen
        expect(lookup_cache(factory)).to be_empty
      end
    end

    it "packs with the default factory once it's made shareable" do
      script = <<~RUBY
        require "msgpack"
        MessagePack::DefaultFactory.register_type(-1, Time, packer: MessagePack::Time::Packer, unpacker: MessagePack::Time::Unpacker)
        Ractor.make_shareable(MessagePack::DefaultFactory)
        ractor = Ractor.new { MessagePack.unpack(MessagePack.pack([1, Time.at(1)])) == [1, Time.at(1)] }
        p(ractor.respond_to?(:value) ? ractor.value : ractor.take)
      RUBY
      lib = File.expand_path("../../lib", __dir__)
      output = IO.popen([RbConfig.ruby, "-W:no-experimental", "-I", lib, "-e", script], err: [:child, :out], &:read)

      expect(output).to eq("true\n")
    end
  end

  module RactorSpec
    Point = Struct.new(:x, :y) do
      def to_msgpack_ext
        [x, y].pack("l>l>")
      end

      def self.from_msgpack_ext(data)
        new(*data.unpack("l>l>"))
      end
    end

    class SubPoint < Point
    end
  end
end
