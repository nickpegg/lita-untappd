require 'untappd'
require 'json'

module Lita
  module Handlers
  class Untappd < Handler
    on :connected, :start_announcer

    route /^untappd fetch/, :manual_fetch, restrict_to: [:admins]
    route /^untappd identify (\w+)/, :associate
    route %r{^[iI](?: a|')m (\w+) on untappd}, :associate, command: true
    route /^untappd known/, :known_users

    route /^untappd forget$/, :forget_me
    route /^untappd forget (\w+)/, :forget_person, restrict_to: [:admins], help: {
      "untappd forget <person>" => "Forgets the person with the given chat name"
    }

    route /^untappd check ?in (.+)/, :checkin

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

    def fetch(userid)
      fetched_checkins = []

      user = User.find_by_id(userid)
      log.debug "Getting checkins for #{user.name}"

      last = redis.get("last_#{userid}")
      last = last ? last.to_i : 0

      log.debug "Last checkin ID: #{last}"

      checkins = ::Untappd::User.feed(redis.get("username_#{userid}")).checkins

      return [] if checkins.nil?

      log.debug "Got #{checkins['count']} potential checkins for #{user.name}"
      checkins.items.reverse.each do |checkin|
        if checkin.checkin_id > last
          last = checkin.checkin_id
          fetched_checkins.push([user, checkin])
        end
      end

      redis.set("last_#{userid}", last)

      log.debug "Got #{fetched_checkins.count} total checkins"

      return fetched_checkins
    end

    def fetch_all
      fetched_checkins = []

      user_keys = redis.keys('username_*')
      user_keys.each do |k|
        jawn, userid = k.split(/_/)
        fetched_checkins += fetch(userid)
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
          robot.send_message(Lita::Source.new(room: config.channel), "#{user.name} drank a #{checkin.beer.beer_name} by #{checkin.brewery.brewery_name}")
        end
      end
      log.info "Announcer started."
    end


    # Route methods
    def associate(response)
      username = response.matches[0][0]

      # Check to make sure the username isn't already taken
      redis.keys("username_*").each do |key|
        redis_username = redis.get(key)
        log.debug ("Redis username: #{redis_username}, username I got: #{username}")

        if !redis_username.nil? and redis_username == username
          response.reply_with_mention("That username is already associated with someone!")
          return
        end
      end

      # [todo] Verify that they're a real Untappd user

      redis.set("username_#{response.user.id}", username)
      response.reply_with_mention("got it")

      # stash last checkin ID, avoid wharrgarbl
      last_checkin_id = ::Untappd::User.feed(username).checkins.items.first.checkin_id
      redis.set("last_#{response.user.id}", last_checkin_id)

      log.info("Added #{username} (#{response.user.name}) with last checkin_id of #{last_checkin_id}")
    end

    def known_users(response)
      redis.keys("username_*").each do |key|
        username = redis.get(key)
        nick = User.find_by_id(key.split(/_/).last)

        response.reply("#{nick.name} is #{username}")
      end
    end

    def forget_me(response)
      redis.del("username_#{response.user.id}")
      redis.del("last_#{response.user.id}")

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

      redis.del("username_#{user.id}")
      redis.del("last_#{user.id}")

      log.info("#{response.user.name} made me forget about #{user.name} who is #{username}")
      response.reply_with_mention("Forgot #{user.name}, who is #{username} on Untappd")
    end

    def manual_fetch(response)
      fetch_all().each do |user, checkin|
        response.reply("#{user.name} drank a #{checkin.beer.beer_name} by #{checkin.brewery.brewery_name}")
      end
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
