require "rubygems"
require "./lib/isaac/bot"

MSG_FORMAT            = "[%s]: %s"
ACTION_FORMAT         = "(as %s) %s"
PRIVATE_ECHO_FORMAT   = "You said: %s"


COMMAND_RX = /^[!]([a-zA-Z0-9]+)(.*)?$/
ACTION_RX = /^\/me\s(.+)$/

class IIRC
  attr_reader :thread

  def initialize(conf, bridge)
    @config = conf
    @bridge = bridge
    @thread = nil

    @awaiting_names_list = true 
    @names = []
  end

  def start
    $log.info "Starting IRC Bot"

    # Give the bot a handle to config and handler
    conf      = @config
    handler   = self

    # Configure the bot
    @bot = Isaac::Bot.new do
      configure{|c|
        c.server   = conf[:server]
        c.port     = conf[:port]
        c.ssl      = conf[:ssl]
        c.nick     = conf[:nick]
        c.password = conf[:password]
        c.realname = conf[:name]

        c.environment = :production
        c.verbose     = true 
        #c.verbose     = false 
      }

      # TODO: handle join/part/quit to maintain names list 

      # NAMES Reply
      on :"353" do 
        begin
          nicks = raw_msg.params[3].split.map{|n| handler.normalise_nick(n)}
          $log.debug "NAMES: #{nicks}"
          handler.register_names(nicks) #if @awaiting_names_list
        rescue Exception => e
          $log.warn e.to_s
          $log.warn e.backtrace.join("\n")
        end
      end

      # End of names
      on :"366" do
        begin
          $log.debug "END OF NAMES:"
          handler.end_names_list
        rescue Exception => e
          $log.warn e.to_s
        end
      end

      # Someone parted
      on :part do
        begin
          $log.debug "PART: #{nick} #{raw_msg.params}"
          handler.nick_part(handler.normalise_nick(nick), raw_msg.params[1]) if raw_msg.params[0] == conf[:channel]
        rescue Exception => e
          $log.warn e.to_s
        end
      end

      on :quit do
        begin
          $log.debug "QUIT: #{nick} #{raw_msg.params}"
          handler.nick_quit(handler.normalise_nick(nick), raw_msg.params[1]) if raw_msg.params[0] == conf[:channel]
        rescue Exception => e
          $log.warn e.to_s
        end
      end

      on :join do
        begin
          $log.debug "JOIN: #{nick}"
          handler.nick_join(handler.normalise_nick(nick))
        rescue Exception => e
          $log.warn e.to_s
        end
        
      end

      on :nick do
        begin
          $log.debug "NICK CHANGE: #{nick} #{raw_msg.params}"
          handler.nick_change(handler.normalise_nick(nick), raw_msg.params[0])
        rescue Exception => e
          $log.warn e.to_s
        end
      end

      on :connect do
        $log.debug "IRC connected, joining #{conf[:channel]}."
        join conf[:channel]
      end

      on :channel do
        $log.debug "IRC Channel message received"
        begin
          handler.handle_message(:channel, handler.normalise_nick(nick), message)
          $log.debug "COMMAND: #{raw_msg.command.unpack('A' * raw_msg.command.length)}"
        rescue Exception => e
          $log.warn e.to_s
        end
      end

      on :private do
        $log.debug "IRC Privmsg received."
        begin
          handler.handle_message(:private, handler.normalise_nick(nick), message)
        rescue Exception => e
          $log.warn e.to_s
        end
      end
    end


    # Run the bot.
    @thread = Thread.new do
      $log.info "Bot thread started."
      @bot.start
    end
  end

  # Remove prefixes from a nick to make them comparable.
  def normalise_nick(nick)
    return /^[@+]?(.*)$/.match(nick)[1]
  end

  # A user has changed his/her nick.  Respond.
  def nick_change(nick, new_nick)
    @names.delete(nick) if @names.include?(nick)
    @names << new_nick 

    @bridge.add(:xmpp, :irc, SYSTEM_USER, "#{nick} is now known as #{new_nick}")
  end

  # A user has quit.
  def nick_quit(nick, reason=nil)
    nick_part(nick, reason)
  end

  # A user parts the channel
  def nick_part(nick, reason=nil)
    return if not @names.include?(nick)

    @names.delete(nick)
    reason = " (#{reason})" if reason
    @bridge.add(:xmpp, :irc, SYSTEM_USER, "#{nick} just left the IRC channel#{reason}")
  end

  def nick_join(nick)
    return if @names.include?(nick)

    @names << nick 
    @bridge.add(:xmpp, :irc, SYSTEM_USER, "#{nick} has joined the IRC channel.")
  end

  def register_names(names)
    @names += names if @awaiting_names_list
  end

  def end_names_list
    @names.uniq!
    @awaiting_names_list = false
  end

  def handle_message(source, nick, message)
    # TODO --- unify this
    $log.info "IRC received message from #{source} (nick: #{nick}, msg: #{message})"
    case source
    when :channel
      handle_channel_message(nick, message)
    when :private
      handle_private_message(nick, message)
    when :xmpp
      handle_xmpp_message(nick, message)
    end
  end

  def get_user_list
    $log.debug "Requesting NAMES for #{@config[:channel]}"
    #@bot.raw("NAMES #{@config[:channel]}")
    # Handle return... (async, sadly)
    return @names
  end

  def connected?
    @bot.connected?
  end

private

  def send_to_all(nick, message)
    @bridge.add(:xmpp, :irc, nick, message)
    $log.info "Sent a message to the XMPP queue (#{nick}, #{message})"
  end

  def handle_xmpp_message(nick, message)
    $log.info "Received a message from the XMPP queue (#{nick}, #{message})"

    if message =~ ACTION_RX then
      @bot.action(@config[:channel], ACTION_FORMAT % [nick, $1])
    else
      if(nick == SYSTEM_USER)
        say(message)
      else
        say(MSG_FORMAT % [nick, message])
      end
    end
  end

  def handle_channel_message(nick, message)
    $log.info "Received a message from the Channel (#{nick}, #{message})"
    if(message =~ COMMAND_RX) then
      handle_command(:irc, nick, message)
    else
      send_to_all(nick, message)
    end
  end

  def handle_private_message(nick, message)
    $log.info "Received a private message (#{nick}, #{message})"
    say(PRIVATE_ECHO_FORMAT % message, nick)
  end
   

  def handle_command(source, user, message)
    # Only accept commands locally
    return if source == :xmpp

    # Parse message
    message =~ COMMAND_RX          
    cmd = $1.downcase
    args = Shellwords.shellsplit($2)

    $log.debug "IRC Received command: #{cmd}, args: #{args.to_s}"

    # Then handle the actual commands
    # TODO: tidy this up.
    case cmd
    when "users"
      output_userlist()
    else
      say("Unrecognised command!")
    end
  end


  def output_userlist()
    xmpp_users = @bridge.call(:xmpp) do |controller|
      controller.get_user_list
    end
    #irc_users = get_user_list

    say("Users on XMPP: #{xmpp_users.join(", ")}")
  end

  def say(msg, nick = @config[:channel])
    @bot.msg(nick, msg)
  end

end
