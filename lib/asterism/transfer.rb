# Asterism::Transfer for CRuby: files carried in pieces between machines,
# with resending (data/transfer/transfer.rb, the same file the boards load
# at run time; see there). Loaded by `require "asterism/transfer"`.
require "digest/sha2"
require "json"
require_relative "../../data/transfer/transfer"
