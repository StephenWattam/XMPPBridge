require 'rubygems'
require 'blather/client/client'


SYSTEM_USER = "***"
#THREAD_ID = 0
COMMAND_RX = /^[!]([a-zA-Z0-9]+)(.*)?$/
UNKNOWN_USER_NICK = "(unknown)"
HELP_MESSAGE = "To set your nickname, type \"!nick <nickname>\"\nTo List users, type \"!users\"\nTo stop chatting, type \"!quit\"\nTo unsubscribe to, type \"!unsubscribe\"" # TODO


MSG_FORMAT            = "[%s]: %s"

class Subscriber
  attr_reader :nick, :jid, :triggers, :active

  NICK_RX = /^[a-zA-Z0-9_\-]{3,10}$/
  def initialize(jid)
    @jid      = jid
    @nick     = jid.clone
    @triggers = []
    @active   = true
  end

  def active?
    @active
  end

  def close_chat
    @active = false
  end

  def open_chat
    @active = true
  end

  # Set the nick, with a quick regex check
  def nick=(nick)
    if(nick =~ NICK_RX )
      @nick = nick
      return true
    end
    return false
  end

  # Respond to a message or not
  def respond?(msg)
    return true if @active
    ([@nick] + @triggers).each{ |trigger|
      if msg =~ /\b(#{trigger})\b/ 
        open_chat 
        return true 
      end
    }
    return false
  end

  def to_s
    str = @active ? "%s" : "(%s)"
    return str % @nick
  end
end



class IJabber
  attr_reader :thread

  def initialize(conf, bridge)
    @config = conf
    @bridge = bridge

    # Load subscriptions from backing store
    @subscriptions = PersistentHash.new(@config[:subscriptions_file], true)
    $log.info "XMPP Client loaded #{@subscriptions.length} subscriptions."
    @subscriptions.each{|jid, nick| $log.debug "#{jid} as #{nick}"}

    @client = Blather::Client.setup(@config[:id], @config[:pw])
    @thread = nil
  end

  # Start xmpp polling
  def start
    @client.register_handler :subscription, :request? do |s|
      begin
        approve_user
      rescue Exception => e
        $log.warn e.to_s
        $log.warn e.backtrace.join("\n")
      end
    end

    @client.register_handler :message, :chat?, :body do |m|
      begin
        #puts "USER: #{user} (#{user.class}) (Nick: '#{@subscriptions[user]}')"
        user = m.from.strip!.to_s
        handle_message(:private, user, m.body) if user != @config[:id]
      rescue Exception => e
        $log.warn e.to_s
        $log.warn e.backtrace.join("\n")
      end
    end

    @thread = Thread.new do
      EM.run do
        @client.run
      end
    end
  end


  def handle_message(source, user, message)
    $log.info "XMPP received message from #{source} (nick: #{user}, msg: #{message})"
    
    case source
    when :private
      if not @subscriptions[user] then
        $log.debug "User is not subscribed."
        subscribe(user)
        help(user)
      else
        # Always open chat if the user speaks
        open_chat(user) if not @subscriptions[user].active?

        if(message =~ COMMAND_RX) then
          $log.debug "User is subscribed, parsing command."
          handle_command(source, user, message)
        else
          $log.debug "Subscribed but is not a command, sending to other clients"
          send_to_all(user, message)
        end
      end
    when :irc
      $log.debug "Received from IRC, sending to subscribers"
      send_to_xmpp(user, message)
    else
      $log.warn "Unknown source of message: #{source}."
    end
  end
  
  def get_user_list
    # TODO: delete_if not sub.active
    return @subscriptions.values.map{|sub| sub.to_s }
  end

  def connected?
    return @client.connected?
  end

private

  def handle_command(source, user, message)
    # Only accept commands locally
    return if source != :private

    # Parse message
    message =~ COMMAND_RX          
    cmd = $1.downcase
    args = Shellwords.shellsplit($2)

    $log.debug "XMPP Received command: #{cmd}, args: #{args.to_s}"

    # Then handle the actual commands
    # TODO: tidy this up.
    case cmd
    when "subscribe"
        subscribe(user)
    when "unsubscribe"
        unsubscribe(user)
    when "nick"
      set_nick(user, args[0])
    when "users"
      output_userlist(user)
    when "quit"
      close_chat(user)
    else
      say(user, "Unrecognised command!")
    end
  end

# Commands ----------------------------------
  
  # No longer send messages to a user unless they
  # either have their name mentioned, or start talking
  # to us again
  def close_chat(jid)
    if not @subscriptions[jid] 
      say(jid, "You are not subscribed!")
      return
    end

    send_to_all(jid, "Goodbye!  Say my nick to hail me.")
    @subscriptions[jid].close_chat
    @subscriptions.save
    say(jid, "You will no longer receive messages until you speak again, or are hailed.")
  end

  def output_userlist(jid)
    irc_users = @bridge.call(:irc) do |controller|
      controller.get_user_list
    end
    xmpp_users = get_user_list

    say(jid, "Users on IRC: #{irc_users.join(", ")}\nUsers on XMPP: #{xmpp_users.join(", ")}")
  end
  
  def subscribe(jid)
    if @subscriptions[jid]
      @subscriptions[jid].open_chat
      say(jid, "You are already subscribed.  I have made sure you're in on the conversation though.") 
      return
    end

    # subscribe
    add_subscription(jid)
    say(jid, "You are now subscribed.")
    msg = "User #{jid} just subscribed.  We now have #{@subscriptions.length} subscription[s]."
    @bridge.add(:irc, :xmpp, SYSTEM_USER, msg)
    send_to_xmpp(SYSTEM_USER, msg, jid)
  end

  def unsubscribe(jid)
    if not @subscriptions[jid]
      say(jid, "You are not subscribed!") 
      return
    end

    # unsubscribe
    old_nick = @subscriptions[jid]
    @subscriptions.delete(jid)
    @subscriptions.save
    say(jid, "You are now unsubscribed.  Send another message to be re-subscribed.")
    msg = "User #{old_nick} (#{jid}) just unsubscribed.  We now have #{@subscriptions.length} subscription[s]."
    @bridge.add(:irc, :xmpp, SYSTEM_USER, msg)
    send_to_xmpp(SYSTEM_USER, msg)
  end

  def help(user)
    $log.info "Presenting help message to user #{user}"
    say(user, HELP_MESSAGE)
  end

  def send_to_xmpp(nick, message, jid = nil)
    # If the nick is not useful, don't display it
    fmt_message = message
    fmt_message = MSG_FORMAT % [nick, message] if(nick and nick != SYSTEM_USER)

    # If a user is set to "respond", send to him
    @subscriptions.each{|s_jid, sub|
      # only send to those users who wish to hear (nick mentioned or set active)
      if(sub.respond? message)
        # Send only to those users who are not the original source of the message
        say(s_jid, fmt_message) if (not jid) or (s_jid != jid)
      end
    }
  end

  def send_to_all(jid, message)
    nick = UNKNOWN_USER_NICK
    nick = @subscriptions[jid].nick if @subscriptions[jid]

    # Send to IRC  
    @bridge.add(:irc, :xmpp, nick, "#{message}")

    # Send message to all but themself
    send_to_xmpp(@subscriptions[jid] ? @subscriptions[jid].nick : "<Unknown>", message, jid)
  end

# Helpers ------------------------------------

  def open_chat(jid)
    if not @subscriptions[jid] 
      say(jid, "You are not subscribed!")
      return
    end

    # Start talking again and save
    @subscriptions[jid].open_chat
    @subscriptions.save
    $log.info "Opened chat for #{jid}"
  end

  def approve_user(request)
    $log.info "Approving user from request #{request}"
    @client.write request.approve!
  end

  def add_subscription(jid, nick = nil)
    $log.info "Adding subscription for user #{jid} as nick '#{nick}'"
    nick = jid.to_s if not nick
    @subscriptions[jid] = Subscriber.new(jid)
    @subscriptions.save
  end


  # Set the nick then save subscriptions
  def set_nick(jid, nick = nil)
    # Check he's subscribed
    if not @subscriptions[jid] then
      say(jid, "You are not subscribed, so cannot change your nick.")
      return
    end

    # Check it's unique
    if(@subscriptions.values.map{|sub| sub.nick}.include? nick) then
      say(jid, "That nick is already taken, sorry.")
      return
    end

    # Try to assign
    old_nick = @subscriptions[jid].nick
    if(@subscriptions[jid].nick = nick) then
      say(jid, "You are now known as #{@subscriptions[jid].nick}.")
      $log.info "#{old_nick} is now known as #{@subscriptions[jid].nick}."
      send_to_all(jid, "#{old_nick} is now known as #{@subscriptions[jid].nick}.")
    else
      $log.info "#{old_nick} failed to change his nick."
      say(jid, "Your requested nick was not accepted.")
    end
    @subscriptions.save
  end

  def say(jid, message)
    @client.write Blather::Stanza::Message.new(jid, message)
  end
end
