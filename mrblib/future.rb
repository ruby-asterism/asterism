module Asterism
  # The answer to a call that is on its way (Proxy#async). done? never
  # waits; value waits (polling, and answering calls meanwhile) until the
  # answer or the time limit, then returns the value or raises.
  class Future
    attr_reader :path, :method_name

    # @api private
    def self.answered(path, method, reply)
      f = new(path, method, nil, 0, 0)
      f.set_reply(reply)
      f
    end

    def initialize(path, method, get, deadline_ms, timeout_ms)
      @path = path
      @method_name = method.to_s
      @get = get
      @deadline = deadline_ms
      @timeout_ms = timeout_ms
      @reply = nil
      @finished = false
      @started = ::Asterism.now_ms
      @took = nil
    end

    # @api private
    def set_reply(reply)
      @reply = reply
      @finished = true
      @took = 0
    end

    # Milliseconds from the call to its answer (nil until done).
    def took_ms
      @took
    end

    # The same in seconds (a Float; nil until done).
    def took
      @took.nil? ? nil : @took / 1000.0
    end

    # True once the answer came, the time ran out or the connection closed.
    # Call Asterism.poll in the update loop for it to move on.
    def done?
      collect
      @finished
    end

    # The answer: {"value" => v} gives v, {"error" => {"kind", "class",
    # "message"}} raises RemoteError; anything else is a malformed answer.
    def value
      raw = raw_value
      raise ::Asterism::Error, "malformed answer from #{@path}" unless raw.is_a?(Hash)
      if raw.key?("error")
        e = raw["error"]
        raise ::Asterism::Error, "malformed answer from #{@path}" unless e.is_a?(Hash)
        kind = e["kind"]
        raise ::Asterism::RemoteError.new(e["class"], e["message"], kind.is_a?(String) ? kind : nil)
      end
      raise ::Asterism::Error, "malformed answer from #{@path}" unless raw.key?("value")
      raw["value"]
    end

    # The decoded answer (meta and profile replies are not value maps).
    def raw_value
      ::Asterism.wait_until { done? } unless done?
      if @reply.nil?
        raise ::Asterism::Disconnected, (::Asterism.lost_reason || "not connected") unless ::Asterism.connected?
        if @took && @took < @timeout_ms
          # Finished early without a reply: nobody answers that key (the
          # object is not exposed, or its application is gone).
          raise ::Asterism::TimeoutError, "no answer from #{@path} #{@method_name} (nobody answers)"
        end
        raise ::Asterism::TimeoutError,
              "no answer from #{@path} #{@method_name} within #{@timeout_ms / 1000.0} s (#{@timeout_ms} ms)"
      end
      raw = ::Asterism::Codec.unpack(@reply)
      raise ::Asterism::Error, "malformed answer from #{@path}" if raw.nil?
      raw
    end

    # @api private
    def collect
      return if @finished
      g = @get
      # done? before taking the replies: with a binding whose replies come
      # in on another thread (zenoh-c), a reply and the end of the get may
      # both arrive between the two; read the other way round, the get
      # would look finished with its reply still queued.
      ended = g.done?
      # The Array form, not a block: a block called from C costs another
      # interpreter entry on the C stack, and this runs inside nested waits.
      replies = g.each_reply
      @reply = replies[0][1] if @reply.nil? && replies.size > 0
      if !@reply.nil? || ended || ::Asterism.now_ms >= @deadline || !::Asterism.connected?
        @finished = true
        @took = ::Asterism.now_ms - @started
      end
    end
  end
end
