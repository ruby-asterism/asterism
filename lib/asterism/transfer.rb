# Asterism::Transfer for CRuby: files carried in pieces between machines,
# with resending (data/transfer/transfer.rb, the same file the boards load
# at run time; see there). Loaded by `require "asterism/transfer"`.
#
# CRuby only, besides: FileInbox (the receiver of the kind "file", with the
# rules of a Family mruby machine) and Endpoint (an inbox answering at
# <node>/transfer/inbox beside the program's own application).
require "digest/sha2"
require "fileutils"
require "json"
require "monitor"
require_relative "../../data/transfer/transfer"
require_relative "transfer/file_inbox"
require_relative "transfer/endpoint"
