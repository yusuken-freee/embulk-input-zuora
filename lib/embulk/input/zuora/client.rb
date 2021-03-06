require 'httpclient'
require 'perfect_retry'
require 'json'

module Embulk
  module Input
    module Zuora
      class Client
        attr_reader :config

        def initialize(config)
          @config = config
        end

        def httpclient
          clnt = HTTPClient.new
          clnt.connect_timeout = 300
          clnt.receive_timeout = 300
          auth(clnt)
          clnt
        end

        def export(&block)
          puts config
          fetched_records = []
          first_path  = endpoint_suffix(true)
          first_query = {"queryString": zoql.compose }.to_json
          first_response_body = JSON.parse(request(first_path, first_query).body)

          query_locator = first_response_body["queryLocator"]
          fetched_records << first_response_body["records"]

          path = endpoint_suffix
          while true
            query = {"queryLocator": query_locator}.to_json
            response_body = JSON.parse(request(path, query).body)
            query_locator = response["queryLocator"]
            fetched_records << response_body["records"]
            break if response_body["done"]
          end
          fetched_records.flatten.each do |record|
            block.call record
          end
        end

        def request(path, query)
          uri = URI.parse(config[:base_url])
          uri.path = path

          puts uri.to_s
          puts query

          retryer.with_retry do
            Embulk.logger.debug "Fetching #{uri.to_s}"
            response = httpclient.post(uri.to_s, query, "Content-Type"=>"application/json")
            handle_response(response.status_code, response.reason, response.body)
            response
          end
        end

        def auth(httpclient)
          case config[:auth_method]
          when "basic"
            httpclient.set_auth(config[:base_url], config[:username], config[:password])
          #when "oauth"
          #  httpclient.default_header["Authorization"] = "Bearer #{oauth_token}"
          end
          httpclient
        end

        def validate_credentials
          case config[:auth_method]
          when "basic"
            config[:username] && config[:password]
          #when "oauth"
          #  config[:oauth_token]
          else
            raise Embulk::ConfigError.new("Unknown auth_method #{config[:auth_method]}.")
          end
        end

        def endpoint_suffix(initial = false)
          path_suffix = initial ? "/action/query" : "/action/queryMore"
          "/v1#{path_suffix}"
        end

        def zoql
          Zoql.new(config)
        end

        def retryer
          PerfectRetry.new do |config|
            config.limit = @config[:retry_limit]
            config.sleep = lambda {|n| @config[:retry_wait_sec] + (2 ** (n-1))}
            config.logger = Embulk.logger
            config.dont_rescues = [Embulk::DataError, Embulk::ConfigError]
            config.raise_original_error = true
            config.log_level = nil
          end
        end

        def handle_response(status_code, status_reason, body)
          case status_code
          when 200
          when 400, 401, 500
            raise Embulk::ConfigError.new("#{status_reason}: #{body["message"]}")
          else
            raise Embulk::ConfigError.new("Uncaught status_code #{status_code}. #{body["message"]}")
          end
        end
      end
    end
  end
end
