#!/usr/bin/env ruby
require 'rubygems'
require 'thread'
require 'yaml'
require 'logger'
require './i_jabber'
require './i_irc'
require 'timeout'
require './persistent_hash.rb'

CONFIG_FILE   = "config.yml"
LOG_FILE      = $stdout


# Open global items
$config       = PersistentHash.new(CONFIG_FILE, true)
$log          = Logger.new(LOG_FILE)
$log.level    = Logger::DEBUG


class Bridge
  def initialize()
    @queue_controllers  = {:irc => nil, :xmpp => nil}#, :system => nil}
    @lock               = Mutex.new
  end

  def set_controller(to, controller)
    @queue_controllers[to] = controller
  end

  def call(to, &block)
    $log.debug "Handling call to #{to}."
    @lock.lock
      $log.warn "Controller #{to} does not exist." if not @queue_controllers[to]
      result = block.call( @queue_controllers[to] ) if @queue_controllers[to]
    @lock.unlock
    $log.debug "Returning value #{result} from call."
    return result
  end

  def add(to, from, nick, message)

    $log.debug "Handling add from #{from} to #{to}."
    $log.warn "Controller #{to} does not exist." if not @queue_controllers[to]
    $log.warn "Controller #{to} is not connected." if @queue_controllers[to] and not @queue_controllers[to].connected?

    if(@queue_controllers[to] and @queue_controllers[to].connected?)
      call(to) do |controller|
        controller.handle_message(from, nick, message)
      end
    end
  end

end




# Create the bridge
bridge = Bridge.new

# Create objects acting as clients
irc_bot   = IIRC.new($config[:irc], bridge)
xmpp_bot  = IJabber.new($config[:xmpp], bridge)

# Assign objects for IPC managed by bridge
bridge.set_controller(:irc, irc_bot)
bridge.set_controller(:xmpp, xmpp_bot)

# Start the clients
irc_bot.start
xmpp_bot.start

loop do
  sleep
end
