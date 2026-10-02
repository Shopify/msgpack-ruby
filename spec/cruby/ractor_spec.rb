require 'spec_helper'

if defined?(Ractor)
  describe "Ractor" do
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
  end
end
