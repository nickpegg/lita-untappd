require 'untappd'
require 'json'

module Lita
  module Handlers # rubocop:disable Style/Documentation
    # Handler to pull Untappd checkins and announce them into a room
    class Untappd < Lita::Handler
      config(:client_id, type: String)      # Untappd client ID
      config(:client_secret, type: String)  # Untappd client secret
      config(:room, type: String)           # Room to accounce new checkins
      config(:interval, type: [Integer, Float], default: 5) # Interval in minutes to check for new checkins

      on :connected, :start_announcer

      route(/^untappd fetch/, :manual_fetch, restrict_to: [:admins])
      route(
        /^untappd identify (\w+)/,
        :associate_me,
        command: true,
        help: {
          'untappd identify <username>' =>
            'Associates <username> on Untappd to you, will start announcing beers you drink'
        }
      )
      route(
        /^[iI](?: a|')m (\w+) on (?:U|u)ntappd/,
        :associate_me,
        command: true,
        help: {
          'I am <username> on untappd' =>
            'Associates <username> on Untappd to you, will start announcing beers you drink'
        }
      )
      route(
        /^untappd known/,
        :known_users,
        command: true,
        help: {
          'untappd known' => 'List all known Untappd users'
        }
      )

      route(
        /^untappd last ?(\w+)?/,
        :last_checkins,
        command: true,
        help: {
          'untappd last' => 'Show your last three beers',
          'untappd last <username>' => 'Show the last three beers that <username> has drank'
        }
      )

      route(
        /^untappd forget$/,
        :forget_me,
        command: true,
        help: {
          'untappd forget' => 'Forgets who you are on Untappd'
        }
      )

      route(
        /^untappd forget (\w+)/,
        :forget_person,
        command: true,
        restrict_to: [:admins],
        help: {
          'untappd forget <person>' => 'Forgets the person with the given chat name'
        }
      )

      # route(/^untappd check ?in (.+)/, :checkin)

      # Debugging routes
      route(/^untappd debug fetch (\w+)$/, :debug_fetch, restrict_to: [:admins])
      route(/^untappd debug nuke$/, :debug_nuke, restrict_to: [:admins])

      def initialize(robot)
        super(robot)

        if config.client_id.empty? || config.client_secret.empty?
          log.error 'You need to specify an Untappd client ID and secret in your config'
        end

        ::Untappd.configure do |c|
          c.client_id = config.client_id
          c.client_secret = config.client_secret
        end
      end

      def fetch(username)
        # TODO: refactor this to use fetch_beers
        fetched_checkins = []
        user = Lita::User.find_by_id(redis.get("id_#{username}"))

        log.debug("Getting checkins for #{user.name}")

        last = redis.get("last_#{username}")
        last = last ? last.to_i : 0

        log.debug "Last checkin ID: #{last}"

        checkins = ::Untappd::User.feed(username).checkins

        return [] if checkins.nil?

        log.debug "Got #{checkins['count']} potential checkins for #{username}"
        checkins.items.reverse_each do |checkin|
          log.debug "Potential checkin: #{checkin.checkin_id} #{checkin.beer.beer_name}"
          if checkin.checkin_id > last
            last = checkin.checkin_id
            fetched_checkins.push([user, checkin])
          end
        end

        redis.set("last_#{username}", last)

        log.debug "Got #{fetched_checkins.count} new checkins"

        fetched_checkins
      end

      def fetch_all
        fetched_checkins = []

        redis.smembers('users').each do |username|
          fetched_checkins += fetch(username)
        end

        fetched_checkins
      end

      def associate(lita_user, untappd_user)
      end

      # Event handlers
      def start_announcer(_payload)
        if config.room.nil?
          log.info 'Not configured to announce in a room.'
          return
        end

        # Periodically grab new beers that people have drank and announce them to the configured room
        every(config.interval * 60) do
          fetch_all.each do |user, checkin|
            # TODO: see if there's a better way to do this than yelling at _some room
            # TODO: Announce earned badges
            log.info "Telling #{config.room} about checkin #{checkin.checkin_id} from #{user.name}"
            robot.send_message(
              Lita::Source.new(room: config.room),
              "#{user.name} drank a #{checkin.beer.beer_name} by #{checkin.brewery.brewery_name}"
            )
          end
        end
        log.info "Announcer started, announcing every #{config.interval} minutes"
      end

      # Route methods
      def associate_me(response)
        username = response.matches[0][0]

        # Check to make sure the username isn't already taken
        log.debug("Checking to make sure #{username} isn't already associated with someone")

        if username == redis.get("username_#{response.user.id}")
          response.reply_with_mention("You're already associated with #{username}")
          return
        end

        if redis.get("username_#{response.user.id}")
          response.reply_with_mention("Someone is already associated as #{username}")
          return
        end

        if redis.sismember('users', username)
          response.reply_with_mention('That username is already associated with someone!')
          return
        end

        # Verify that they're a real Untappd user
        user_info = ::Untappd::User.info(username)
        if user_info.empty?
          response.reply_with_mention("#{username} doesn't exist on Untappd")
          return
        end

        # Remember them
        redis.set("username_#{response.user.id}", username)
        redis.set("id_#{username}", response.user.id)
        redis.sadd('users', username)

        # stash last checkin ID, avoid wharrgarbl
        last_checkin = ::Untappd::User.feed(username).checkins.items.first
        if last_checkin
          # TODO: tell the user their last beer
          redis.set("last_#{username}", last_checkin.checkin_id)

          last_beer = "#{last_checkin.beer.beer_name} by #{last_checkin.brewery.brewery_name}"
          log.info("Added #{username} (#{response.user.name}), last beer: #{last_beer}, " \
                   "checkin_id #{last_checkin.checkin_id}")
          response.reply_with_mention("Got it, you're #{username} on Untappd, you last drank #{last_beer}")
        else
          redis.set("last_#{username}", 0)
          response.reply_with_mention("Got it, you're #{username} on Untappd")
        end
      end

      def known_users(response)
        known_users = redis.smembers('users')

        if known_users.empty?
          response.reply("I don't know anyone on Untappd")
        else
          known_users.each do |username|
            nick = User.find_by_id(redis.get("id_#{username}"))
            response.reply("#{nick.name} is #{username} on Untappd")
          end
        end
      end

      # Posts the last three beers of a user, or the last day's worth, whichever is more
      def last_checkins(response)
        user = response.matches.first.first || response.user

        if redis.sismember('users', user)
          untappd_user = user
        else
          # look up the Untappd user for this chat user
          chat_user = User.fuzzy_find(user)

          unless chat_user
            response.reply_with_mention("I don't know anyone by that name")
            return
          end

          untappd_user = redis.get("username_#{chat_user.id}")
        end

        # Get the last three or today's checkins, whichever is more
        checkins = ::Untappd::User.feed(untappd_user).checkins.items
        last_24_hour_checkins = checkins.find_all do |checkin|
          Time.parse(checkin.created_at) > (Time.now - (60 * 60 * 24))
        end

        if last_24_hour_checkins.length >= 3
          checkins = last_24_hour_checkins
        else
          checkins = checkins.take 3
        end

        # accounce last beers
        beers = []
        checkins.each do |checkin|
          beers << "#{checkin.beer.beer_name} by #{checkin.brewery.brewery_name}"
        end

        response.reply("#{user}'s last few beers: #{beers.join(', ')}")
      end

      def forget_me(response)
        username = redis.get("username_#{response.user.id}")

        redis.del("username_#{response.user.id}")
        redis.del("id_#{username}")
        redis.srem('users', username)
        redis.del("last_#{username}")

        log.info("#{response.user.name} made me forget about them, they were #{username}")
        response.reply_with_mention("You've been disassociated with Untappd")
      end

      def forget_person(response)
        user = User.find_by_name(response.matches[0][0])
        if user.nil?
          response.reply_with_mention("I don't know about #{user}")
          return
        end

        username = redis.get("username_#{user.id}")

        # TODO: Determine if they actually exist first, only say something if they were removed
        redis.srem('users', username)
        redis.del("username_#{user.id}")
        redis.del("last_#{username}")

        log.info("#{response.user.name} made me forget about #{user.name} who is #{username}")
        response.reply_with_mention("Forgot #{user.name}, who is #{username} on Untappd")
      end

      def manual_fetch(response)
        fetch_all.each do |user, checkin|
          response.reply("#{user.mention_name} drank a #{checkin.beer.beer_name} by #{checkin.brewery.brewery_name}")
        end
      end

      def debug_fetch(response)
        user = response.matches[0][0]

        log.info("Clearing last for #{user} and fetching all available checkins")

        unless redis.sismember('users', user)
          response.reply("I don't know about #{user}")
          return
        end

        # Set last ID to 0 to fetch all checkins
        log.debug("Set last_#{user} to 0")
        redis.set("last_#{user}", 0)

        fetch(user).each do |fetched_user, checkin|
          response.reply("#{fetched_user.name} drank a #{checkin.beer.beer_name} by #{checkin.brewery.brewery_name}")
        end
      end

      def debug_nuke(response)
        # Nuke everything from Redis
        %w(username id last).each do |thing|
          redis.keys("#{thing}_*").each { |k| redis.del(k) }
        end

        redis.del('users')

        log.info("#{response.user.mention_name} nuked the untappd info")
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
