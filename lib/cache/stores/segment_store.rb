module SplitIoClient
  module Cache
    module Stores
      class SegmentStore
        attr_reader :segments_repository

        def initialize(segments_repository, config, api_key, metrics, sdk_blocker = nil)
          @segments_repository = segments_repository
          @config = config
          @api_key = api_key
          @metrics = metrics
          @sdk_blocker = sdk_blocker
        end

        def call
          if ENV['SPLITCLIENT_ENV'] == 'test'
            store_segments
          else
            @sdk_blocker.segments_thread = Thread.new do
              @config.block_until_ready ? blocked_store : unblocked_store
            end
          end
        end

        private

        def blocked_store
          @sdk_blocker.splits_mutex.synchronize do
            loop do
              # NOTE: Waiting for SDK to store all splits and used segment names
              @sdk_blocker.wait_for_splits

              # NOTE: This method stores ALL segments for ALL segment names found in splits
              store_segments
              @config.logger.debug("Segment names: #{@segments_repository.used_segment_names.to_a}") if @config.debug_enabled

              unless @sdk_blocker.ready?
                @sdk_blocker.segments_ready!
                Thread.stop
              end

              sleep(random_interval(@config.segments_refresh_rate))
            end
          end
        end

        def unblocked_store
          loop do
            store_segments

            sleep(random_interval(@config.segments_refresh_rate))
          end
        end

        def store_segments
          segments_api.store_segments_by_names(@segments_repository.used_segment_names)
        rescue StandardError => error
          @config.log_found_exception(__method__.to_s, error)
        end

        def random_interval(interval)
          random_factor = Random.new.rand(50..100) / 100.0

          interval * random_factor
        end

        def segments_api
          SplitIoClient::Api::Segments.new(@api_key, @config, @metrics, @segments_repository)
        end
      end
    end
  end
end
