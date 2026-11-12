# The mruby side of rake test:cross: topics and subscriptions between an
# mruby node and a CRuby one (test/cross_mruby.rb), both through Asterism.
# Node "mdata", app "t", listening as a peer:
#
#   mruby -r msgpack.rb data_node.rb PORT
#
# It defines a type before connecting, publishes imu (vector3, ts) and cam
# (image/jpeg), subscribes to cruby/t/** with |v, info| and to cruby/t/n
# with |v|, and exposes probe: put_imu(n) puts n values on imu, put_cam
# puts the bytes of a small JPEG-like image, unpublish_cam withdraws cam,
# got returns what the subscriptions got ([path, value, seq, time,
# encoding, lost, restarted]; the bytes of a value with an encoding as a
# bin) and plain the values of the |v| block; stop ends the node.
port = ARGV[0]

class Probe
  attr_accessor :stop_now

  def initialize(imu, cam, got, plain)
    @imu = imu
    @cam = cam
    @got = got
    @plain = plain
    @n = 0
  end

  def put_imu(n)
    i = 0
    while i < n
      @n += 1
      @imu.put([0.5, -1, @n])
      i += 1
    end
    @imu.seq
  end

  def put_cam
    @cam.put("\xff\xd8\xff\xe0mruby\xff\xd9".b)
    @cam.seq
  end

  def unpublish_cam
    @cam.close
    Asterism.published
  end

  def got
    @got
  end

  def plain
    @plain
  end

  def stop
    @stop_now = true
    nil
  end
end

Asterism.define_type("mdata/sample", [["id", "int"], ["tags", "str[]"], ["at", :pose], ["trail", "vector3[]"], ["kind", 5]], desc: "a sample")
Asterism.connect(nil, node: "mdata", app: "t", mode: :peer, listen: "tcp/127.0.0.1:#{port}")
imu = Asterism.publish("imu", type: :vector3, unit: "m/s2", desc: "acceleration", ts: true)
cam = Asterism.publish("cam/front", type: :image, encoding: "image/jpeg")
got = []
plain = []
Asterism.subscribe("cruby/t/**") do |v, info|
  v = Asterism::Profile.binary(v) unless info.encoding == "msgpack"
  got << [info.path, v, info.seq, info.time, info.encoding, info.lost, info.restarted?]
end
Asterism.subscribe("cruby/t/n") { |v| plain << v }
probe = Probe.new(imu, cam, got, plain)
Asterism.expose("probe", probe, methods: { put_imu: 1, put_cam: 0, unpublish_cam: 0, got: 0, plain: 0, stop: 0 })
puts "ready"
deadline = Time.now + 60
until probe.stop_now || Time.now > deadline
  Asterism.poll
  usleep 2000
end
t = Time.now
Asterism.poll while Time.now - t < 0.2 # the answer to stop goes out
Asterism.close
puts "data node done"
