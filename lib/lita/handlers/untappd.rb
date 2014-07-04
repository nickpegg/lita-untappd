require 'untappd'
require 'json'

module Lita
  module Handlers
  class Untappd < Handler
    on :connected, :start_announcer

    route /^untappd fetch/, :manual_fetch, restrict_to: [:admins]
    route /^untappd identify (\w+)/, :associate, help: {
      "untappd identify <username>" => "Associates <username> on Untappd to you, will start announcing beers you drink."
    }
    route %r{^[iI](?: a|')m (\w+) on untappd}, :associate, command: true
    route /^untappd known/, :known_users

    route /^untappd forget$/, :forget_me
    route /^untappd forget (\w+)/, :forget_person, restrict_to: [:admins], help: {
      "untappd forget <person>" => "Forgets the person with the given chat name"
    }

    route /^untappd check ?in (.+)/, :checkin

    # Debugging routes
    route /^untappd debug fetch (\w+)$/, :debug_fetch, restrict_to: [:admins]
    route /^untappd debug nuke$/, :debug_nuke, restrict_to: [:admins]


    def self.default_config(config)
      config.client_id = nil
      config.client_secret = nil
      config.channel = nil
      config.interval = 5
    end

    def initialize(robot)
      super(robot)

      ::Untappd.configure do |c|
        c.client_id = config.client_id
        c.client_secret = config.client_secret
      end
    end

    def fetch(username)
      fetched_checkins = []
      user = User.find_by_id(redis.get("id_#{username}"))

      log.debug("Getting checkins for #{user.name}")

      last = redis.get("last_#{username}")
      last = last ? last.to_i : 0

      log.debug "Last checkin ID: #{last}"

      checkins = ::Untappd::User.feed(username).checkins

      return [] if checkins.nil?

      log.debug "Got #{checkins['count']} potential checkins for #{username}"
      checkins.items.reverse.each do |checkin|
        if checkin.checkin_id > last
          last = checkin.checkin_id
          fetched_checkins.push([user, checkin])
        end
      end

      redis.set("last_#{username}", last)

      log.debug "Got #{fetched_checkins.count} total checkins"

      return fetched_checkins
    end

    def fetch_all
      fetched_checkins = []

      redis.smembers("users").each do |username|
        fetched_checkins += fetch(username)
      end

      return fetched_checkins
    end


    # Event handlers
    def start_announcer(payload)
      if config.channel.nil?
        log.info "Not configured to announce in a channel."
        return
      end

      # Periodically grab new beers that people have drank and announce them to the configured channel
      every(config.interval * 60) do |timer|
        fetch_all().each do |user, checkin|
          # [todo] see if there's a better way to do this
          robot.send_message(Lita::Source.new(room: config.channel), "#{user.name} drank a #{checkin.beer.beer_name} by #{checkin.brewery.brewery_name}")
        end
      end
      log.info "Announcer started."
    end


    # Route methods
    def associate(response)
      username = response.matches[0][0]

      # Verify that they're a real Untappd user
      user_info = ::Untappd::User.info(username)
      if user_info.empty?
        response.reply_with_mention("#{username} doesn't exist on Untappd")
        return
      end

      # Check to make sure the username isn't already taken
      log.debug("Checking to make sure #{username} isn't already associated with someone")

      if username == redis.get("username_#{response.user.id}")
        response.reply_with_mention("You're already associated with #{username}")
        return
      end

      if redis.sismember("users", username)
        response.reply_with_mention("That username is already associated with someone!")
        return
      end

      # Remember them
      redis.set("username_#{response.user.id}", username)
      redis.set("id_#{username}", response.user.id)
      redis.sadd("users", username)

      # stash last checkin ID, avoid wharrgarbl
      last_checkin_id = ::Untappd::User.feed(username).checkins.items.first.checkin_id
      redis.set("last_#{username}", last_checkin_id)

      log.info("Added #{username} (#{response.user.name}) with last checkin_id of #{last_checkin_id}")
      response.reply_with_mention("got it")
    end

    def known_users(response)
      redis.smembers("users").each do |username|
        nick = User.find_by_id(redis.get("id_#{username}"))

        response.reply("#{nick.name} is #{username}")
      end
    end

    def forget_me(response)
      username = redis.get("username_#{response.user.id}")

      redis.del("username_#{response.user.id}")
      redis.del("id_#{username}")
      redis.srem("users", username)
      redis.del("last_#{username}")

      log.info("#{response.user.name} made me forget about them")
      response.reply_with_mention("You've been disassociated with Untappd")
    end

    def forget_person(response)
      user = User.find_by_name(response.matches[0][0])
      if user.nil?
        response.reply_with_mention("I don't know about #{response.matches[0][0]}")
        return
      end

      username = redis.get("username_#{user.id}")

      redis.srem("users", username)
      redis.del("username_#{user.id}")
      redis.del("last_#{username}")

      log.info("#{response.user.name} made me forget about #{user.name} who is #{username}")
      response.reply_with_mention("Forgot #{user.name}, who is #{username} on Untappd")
    end

    def manual_fetch(response)
      fetch_all().each do |user, checkin|
        response.reply("#{user.name} drank a #{checkin.beer.beer_name} by #{checkin.brewery.brewery_name}")
      end
    end

    def debug_fetch(response)
      user = response.matches[0][0]

      log.info("Clearing last for #{user} and fetching all available checkins")

      unless redis.sismember("users", user)
        response.reply("I don't know about #{user}")
        return
      end

      # Set last ID to 0 to fetch all checkins
      log.debug("Set last_#{user} to 0")
      redis.set("last_#{user}", 0)

      fetch(user).each do |user, checkin|
        response.reply("#{user.name} drank a #{checkin.beer.beer_name} by #{checkin.brewery.brewery_name}")
      end
    end

    def debug_nuke(response)
      # Nuke everything from Redis
      redis.smembers("users").each do |username|
        userid = redis.get("id_#{username}")

        redis.del("username_#{userid}")
        redis.del("id_#{username}")
        redis.del("last_#{username}")
      end

      redis.del("users")

      log.info("#{response.user.name} nuked the untappd info")
    end

    def checkin(response)
      # Figure out which beer the user is talking about

      # if multiple beers found, PM the user to ask which one

      # check the user in

      response.reply_with_mention("Sorry, that's not implemented yet.")
    end
  end

  Lita.register_handler(Untappd)
  end
end
