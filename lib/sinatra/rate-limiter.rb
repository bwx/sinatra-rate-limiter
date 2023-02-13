require 'sinatra/base'
require 'redis'

module Sinatra

  module RateLimiter

    class Exceeded < StandardError
    end

    module Helpers

      def rate_limit(*args)
        return unless settings.rate_limiter and settings.rate_limiter_environments.include?(settings.environment)

        bucket, options, limits = parse_args(args)

        limiter = RateLimit.new(bucket, limits)
        limiter.settings  = settings
        limiter.request   = request
        limiter.options   = options

        limiter.headers.each{|h,v| response.headers[h] = v} if limiter.options.send_headers

        if (error_locals = limiter.limits_exceeded?)
          response.headers['Retry-After'] = error_locals[:try_again] if limiter.options.send_headers

          request.env['sinatra.error.rate_limiter'] = Struct.new(*error_locals.keys).new(*error_locals.values)
          raise Sinatra::RateLimiter::Exceeded, "#{bucket.eql?('default') ? 'R' : bucket + ' r'}ate limit exceeded"
        end

        limiter.log_request
      end

      private

      def parse_args(args)
        bucket  = (args.first.class == String) ? args.shift : 'default'
        options = (args.last.class == Hash)    ? args.pop   : {}
        limits  = (args.size < 1) ? settings.rate_limiter_default_limits : args

        if (limits.size < 1)
          raise ArgumentError, 'No explicit or default limits values provided.'
        elsif (limits.map{|a| a.class}.select{|a| a != Integer}.count > 0)
          raise ArgumentError, 'Non-Fixnum parameters supplied. All parameters must be Fixnum except the first which may be a String.'
        elsif ((limits.map{|a| a.class}.size % 2) != 0)
          raise ArgumentError, 'Wrong number of Fixnum parameters supplied.'
        elsif !(bucket =~ /^[a-zA-Z0-9\-]*$/)
          raise ArgumentError, 'Limit name must be a String containing only a-z, A-Z, 0-9, and -.'
        end

        options.to_a.each do |option, value|
          case option
          when :send_headers
            raise ArgumentError, 'send_headers must be true or false' if !(value == (true or false))
          when :header_prefix
            raise ArgumentError, 'header_prefix must be a String' if value.class != String
          when :identifier
            raise ArgumentError, 'identifier must be a Proc or String' if value.class != (Proc or String)
          else
            raise ArgumentError, "Invalid option #{option}"
          end
        end

        return [bucket,
                options,
                limits.each_slice(2).map{|a| {requests: a[0], seconds: a[1]}}]
      end

    end

    def self.registered(app)
      app.helpers RateLimiter::Helpers

      app.set :rate_limiter,                  false
      app.set :rate_limiter_environments,     [:production]
      app.set :rate_limiter_default_limits,   [10, 20]  # 10 requests per 20 seconds
      app.set :rate_limiter_default_options, {
        send_headers:   true,
        header_prefix:  'Rate-Limit',
        identifier:     Proc.new{ |request| request.ip }
      }

      app.set :rate_limiter_redis_conn,       Redis.new
      app.set :rate_limiter_redis_namespace,  'rate_limit'
      app.set :rate_limiter_redis_expires,    24*60*60 # This must be larger than longest limit time period

      app.error Sinatra::RateLimiter::Exceeded do
        status 429
        content_type 'text/plain'

        "#{env['sinatra.error.rate_limiter'].bucket.eql?('default') ? 'R' : env['sinatra.error.rate_limiter'].bucket + ' R'}" +
          "ate limit exceeded: #{env['sinatra.error.rate_limiter'].requests} requests" +
          " in #{env['sinatra.error.rate_limiter'].seconds} seconds." +
          " Try again in #{env['sinatra.error.rate_limiter'].try_again} seconds."
      end
    end

    class RateLimit
      attr_accessor :settings, :request, :options

      def initialize(bucket, limits)
        @bucket      = bucket
        @limits      = limits
        @time_prefix = get_min_time_prefix(@limits)
      end

      def options=(options)
        options = settings.rate_limiter_default_options.merge(options)
        @options = Struct.new(*options.keys).new(*options.values)
      end

      def identifier
        @identifier ||= (@options.identifier.class == Proc ? @options.identifier.call(request) : @options.identifier)
      end

      def history(seconds=0)
        redis_history.select{|t| seconds.eql?(0) ? true : t > (Time.now.to_f - seconds)}
      end

      def headers
        headers = []

        header_prefix = @options.header_prefix + (@bucket.eql?('default') ? '' : '-' + @bucket)
        limit_no = 0 if @limits.length > 1
        @limits.each do |limit|
          limit_no = limit_no + 1 if limit_no
          headers << [header_prefix + (limit_no ? "-#{limit_no}" : '') + '-Limit',     limit[:requests]]
          headers << [header_prefix + (limit_no ? "-#{limit_no}" : '') + '-Remaining', limit_remaining(limit)]
          headers << [header_prefix + (limit_no ? "-#{limit_no}" : '') + '-Reset',     limit_reset(limit)]
        end

        return headers
      end

      def limit_remaining(limit)
        limit[:requests] - history(limit[:seconds]).length
      end

      def limit_reset(limit)
        limit[:seconds] - (Time.now.to_f - history(limit[:seconds]).min.to_f).to_i
      end

      def limits_exceeded?
        exceeded = @limits.select {|limit| limit_remaining(limit) < 1}.sort_by{|e| e[:seconds]}.last

        if exceeded
          try_again = limit_reset(exceeded)
          return exceeded.merge({try_again: try_again.to_i, bucket: @bucket})
        end
      end

      def log_request
        redis.setex(
          [namespace, identifier, @bucket, Time.now.to_f.to_s].join('/'),
          @settings.rate_limiter_redis_expires,
          nil)
      end

      private

      def redis_history
        @history ||= redis.
          keys("#{[namespace,identifier,@bucket].join('/')}/#{@time_prefix}*").
          map{|k| k.split('/')[3].to_f}
      end

      def redis
        @settings.rate_limiter_redis_conn
      end

      def namespace
        @settings.rate_limiter_redis_namespace
      end

      def get_min_time_prefix(limits)
        now    = Time.now.to_f
        oldest = Time.now.to_f - limits.sort_by{|l| -l[:seconds]}.first[:seconds]

        return now.to_s[0..((now/oldest).to_s.split(/^1\.|[1-9]+/)[1].length)].to_i.to_s
      end
    end

  end

  register RateLimiter
end
