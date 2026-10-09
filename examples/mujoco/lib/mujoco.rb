# A thin Ruby skin over MuJoCo's C API, through Ruby's standard Fiddle.
# Only what examples/mujoco needs: load a model from XML, make its data,
# step / forward / reset, names to ids, and read and write the arrays of
# mjModel and mjData (qpos, qvel, ctrl, sensordata, xpos, xquat, ...).
#
#   lib = MuJoCo::Lib.open                    # vendor/ or MUJOCO_LIB; checks the version
#   m = MuJoCo::Model.load_xml(lib, "model/scene.xml")
#   d = MuJoCo::Data.new(m)
#   d.step(5)
#   d.read(:qpos, 0, 7)                       # => [x, y, z, qw, qx, qy, qz]
#   d.write(:ctrl, 0, 3.0)
#   d.close; m.close
#
# The structs are not described to Fiddle field by field: the wrapper reads
# the pointers and numbers at the byte offsets of lib/mujoco/layout_<ver>.rb,
# which layout_gen.rb made from the pinned release's headers. A library of
# any other version is refused (Lib.open), since the offsets would be wrong.
# Not thread safe: one Model / Data per thread.
require "fiddle"
require_relative "mujoco/layout_3_15_0"

module MuJoCo
  class Error < StandardError; end
  # The library is not the version the layout was made for.
  class VersionMismatch < Error; end

  # libmujoco.so, opened once, with the functions this wrapper calls.
  class Lib
    VENDOR = File.expand_path("../vendor/mujoco-#{Layout::VERSION}/lib/libmujoco.so.#{Layout::VERSION}", __dir__)

    P = Fiddle::TYPE_VOIDP
    I = Fiddle::TYPE_INT
    V = Fiddle::TYPE_VOID
    SIGS = {
      mj_version: [[], I],
      mj_versionString: [[], P],
      mj_loadXML: [[P, P, P, I], P],
      mj_deleteModel: [[P], V],
      mj_makeData: [[P], P],
      mj_deleteData: [[P], V],
      mj_resetData: [[P, P], V],
      mj_step: [[P, P], V],
      mj_forward: [[P, P], V],
      mj_name2id: [[P, I, P], I]
    }.freeze

    attr_reader :path, :version

    def self.open(path = ENV["MUJOCO_LIB"] || VENDOR)
      new(path)
    end

    def initialize(path)
      unless File.exist?(path)
        raise Error, "#{path} not found: run `ruby examples/mujoco/fetch.rb` (or set MUJOCO_LIB)"
      end

      @path = path
      @handle = Fiddle.dlopen(path)
      @fn = SIGS.to_h do |name, (args, ret)|
        [name, Fiddle::Function.new(@handle[name.to_s], args, ret, name: name.to_s)]
      end
      @version = @fn[:mj_versionString].call.to_s
      number = @fn[:mj_version].call
      return if number == Layout::HEADER_VERSION && @version == Layout::VERSION

      raise VersionMismatch, "#{path} is MuJoCo #{@version} (#{number}); this wrapper's struct layout is for " \
                             "#{Layout::VERSION} (#{Layout::HEADER_VERSION}). Fetch the pinned release, or " \
                             "regenerate the layout (layout_gen.rb) for this one"
    end

    def call(name, *args)
      @fn.fetch(name).call(*args)
    end
  end

  # Reading and writing at an address. Fiddle::Pointer#[] / []= copy bytes.
  module Memory
    module_function

    def ptr(addr, size) = Fiddle::Pointer.new(addr, size)
    def int64(addr) = ptr(addr, 8)[0, 8].unpack1("q<")
    def address(addr) = ptr(addr, 8)[0, 8].unpack1("Q<")
    def double(addr) = ptr(addr, 8)[0, 8].unpack1("E")
    def doubles(addr, n) = ptr(addr, 8 * n)[0, 8 * n].unpack("E#{n}")
    def ints(addr, n) = ptr(addr, 4 * n)[0, 4 * n].unpack("l<#{n}")
    def put_double(addr, v) = (ptr(addr, 8)[0, 8] = [v.to_f].pack("E"))
  end

  # Array fields of a struct at a base address, by the layout's table:
  # [offset, kind]. Pointer fields are read once (MuJoCo does not move them
  # after mj_makeData / mj_loadXML).
  module Fields
    def field_addr(name)
      @addrs[name] ||= begin
        off, kind = self.class::TABLE.fetch(name) { raise ArgumentError, "#{name} is not in the layout" }
        raise ArgumentError, "#{name} is not an array" unless kind.end_with?("_ptr")

        a = Memory.address(@addr + off)
        raise Error, "#{name} is NULL" if a.zero?

        a
      end
    end

    def scalar(name)
      off, kind = self.class::TABLE.fetch(name)
      case kind
      when :size then Memory.int64(@addr + off)
      when :num then Memory.double(@addr + off)
      else raise ArgumentError, "#{name} is an array"
      end
    end

    # n values from index i of an array field (mjtNum* gives Floats, int* Integers)
    def read(name, i, n = 1)
      _, kind = self.class::TABLE.fetch(name)
      if kind == :num_ptr
        Memory.doubles(field_addr(name) + 8 * i, n)
      else
        Memory.ints(field_addr(name) + 4 * i, n)
      end
    end
  end

  class Model
    include Fields
    TABLE = Layout::MODEL
    # Sizes a model of this example is expected to stay under (a wrong
    # offset reads garbage, which is almost never this small and positive).
    SANE = 1_000_000

    attr_reader :lib, :addr, :nq, :nv, :nu, :nbody, :njnt, :ngeom, :nsite, :nsensor, :nsensordata, :timestep

    def self.load_xml(lib, path)
      raise Error, "#{path} not found" unless File.exist?(path)

      err = Fiddle::Pointer.malloc(1000, Fiddle::RUBY_FREE)
      err[0] = 0
      m = lib.call(:mj_loadXML, path, nil, err, 1000)
      raise Error, "mj_loadXML #{path}: #{err.to_s}" if m.null?

      new(lib, m.to_i)
    end

    def initialize(lib, addr)
      @lib = lib
      @addr = addr
      @addrs = {}
      @nq, @nv, @nu, @nbody, @njnt, @ngeom, @nsite, @nsensor, @nsensordata =
        %i[nq nv nu nbody njnt ngeom nsite nsensor nsensordata].map { |n| scalar(n) }
      @timestep = scalar(:opt_timestep)
      sizes = [@nq, @nv, @nu, @nbody, @njnt, @ngeom, @nsite, @nsensor, @nsensordata]
      unless sizes.all? { |s| s.between?(0, SANE) } && @nbody >= 1 && @timestep.positive? && @timestep < 1.0
        raise Error, "the model's sizes read as #{sizes.inspect}, timestep #{@timestep}: the layout does not fit " \
                     "this library"
      end
    end

    # mj_name2id; raises when there is no such name (MuJoCo gives -1)
    def id(type, name)
      t = Layout::OBJ.fetch(type) { raise ArgumentError, "unknown object type #{type}" }
      i = @lib.call(:mj_name2id, @addr, t, name.to_s)
      raise Error, "no #{type} named #{name}" if i.negative?

      i
    end

    def close
      return unless @addr

      @lib.call(:mj_deleteModel, @addr)
      @addr = nil
    end
  end

  class Data
    include Fields
    TABLE = Layout::DATA

    attr_reader :model, :addr

    def initialize(model)
      @model = model
      @lib = model.lib
      d = @lib.call(:mj_makeData, model.addr)
      raise Error, "mj_makeData failed" if d.null?

      @addr = d.to_i
      @addrs = {}
      forward
      check
    end

    def step(n = 1)
      i = 0
      while i < n
        @lib.call(:mj_step, @model.addr, @addr)
        i += 1
      end
      self
    end

    def forward = (@lib.call(:mj_forward, @model.addr, @addr); self)

    def reset
      @lib.call(:mj_resetData, @model.addr, @addr)
      forward
    end

    def time = scalar(:time)

    def write(name, i, value)
      _, kind = TABLE.fetch(name)
      raise ArgumentError, "#{name} is not an mjtNum array" unless kind == :num_ptr

      Memory.put_double(field_addr(name) + 8 * i, value)
    end

    def close
      return unless @addr

      @lib.call(:mj_deleteData, @addr)
      @addr = nil
    end

    private

    # After mj_forward the world body sits at the origin with the identity
    # orientation and the clock is at 0: a cheap check that the offsets of
    # mjData read what they should.
    def check
      ok = time.zero? && read(:xpos, 0, 3) == [0.0, 0.0, 0.0] && read(:xquat, 0, 4) == [1.0, 0.0, 0.0, 0.0]
      raise Error, "mjData does not read as expected (time #{time}, world #{read(:xquat, 0, 4)})" unless ok
    end
  end
end
