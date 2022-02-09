# frozen_string_literal: true

require 'spec_helper'
require 'http_server_mock'

describe SplitIoClient::SSE::EventSource::Client do
  subject { SplitIoClient::SSE::EventSource::Client }

  let(:log) { StringIO.new }
  let(:config) { SplitIoClient::SplitConfig.new(logger: Logger.new(log)) }
  let(:telemetry_runtime_producer) { SplitIoClient::Telemetry::RuntimeProducer.new(config) }
  let(:telemetry_runtime_consumer) { SplitIoClient::Telemetry::RuntimeConsumer.new(config) }
  let(:api_token) { 'api-token-test' }
  let(:event_parser) { SplitIoClient::SSE::EventSource::EventParser.new(config) }
  let(:repositories) do
    {
      splits: SplitIoClient::Cache::Repositories::SplitsRepository.new(config),
      segments: SplitIoClient::Cache::Repositories::SegmentsRepository.new(config),
      impressions: SplitIoClient::Cache::Repositories::ImpressionsRepository.new(config),
      events: SplitIoClient::Cache::Repositories::EventsRepository.new(config, api_key, telemetry_runtime_producer)
    }
  end
  let(:parameters) do
    {
      split_fetcher: SplitIoClient::Cache::Fetchers::SplitFetcher.new(splits_repository, api_key, config, telemetry_runtime_producer),
      segment_fetcher: SplitIoClient::Cache::Fetchers::SegmentFetcher.new(segments_repository, api_key, config, telemetry_runtime_producer),
      imp_counter: SplitIoClient::Engine::Common::ImpressionCounter.new,
      telemetry_runtime_producer: telemetry_runtime_producer
    }
  end
  let(:synchronizer) { SplitIoClient::Engine::Synchronizer.new(repositories, api_key, config, parameters) }
  let(:splits_worker) { SplitIoClient::SSE::Workers::SplitsWorker.new(synchronizer, config, repositories[:splits]) }
  let(:segments_worker) { SplitIoClient::SSE::Workers::SegmentsWorker.new(synchronizer, config, repositories[:segments]) }
  let(:notification_manager_keeper) { SplitIoClient::SSE::NotificationManagerKeeper.new(config, telemetry_runtime_producer) }
  let(:notification_processor) { SplitIoClient::SSE::NotificationProcessor.new(config, splits_worker, segments_worker) }

  let(:event_split_update) { "fb\r\nid: 123\nevent: message\ndata: {\"id\":\"1\",\"clientId\":\"emptyClientId\",\"connectionId\":\"1\",\"timestamp\":1582045421733,\"channel\":\"channel-test\",\"data\":\"{\\\"type\\\" : \\\"SPLIT_UPDATE\\\",\\\"changeNumber\\\": 5564531221}\",\"name\":\"asdasd\"}\n\n\r\n" }
  let(:event_split_kill) { "fb\r\nid: 123\nevent: message\ndata: {\"id\":\"1\",\"clientId\":\"emptyClientId\",\"connectionId\":\"1\",\"timestamp\":1582045421733,\"channel\":\"channel-test\",\"data\":\"{\\\"type\\\" : \\\"SPLIT_KILL\\\",\\\"changeNumber\\\": 5564531221, \\\"defaultTreatment\\\" : \\\"off\\\", \\\"splitName\\\" : \\\"split-test\\\"}\",\"name\":\"asdasd\"}\n\n\r\n" }
  let(:event_segment_update) { "fb\r\nid: 123\nevent: message\ndata: {\"id\":\"1\",\"clientId\":\"emptyClientId\",\"connectionId\":\"1\",\"timestamp\":1582045421733,\"channel\":\"channel-test\",\"data\":\"{\\\"type\\\" : \\\"SEGMENT_UPDATE\\\",\\\"changeNumber\\\": 5564531221, \\\"segmentName\\\" : \\\"segment-test\\\"}\",\"name\":\"asdasd\"}\n\n\r\n" }
  let(:event_control) { "fb\r\nid: 123\nevent: message\ndata: {\"id\":\"1\",\"clientId\":\"emptyClientId\",\"connectionId\":\"1\",\"timestamp\":1582045421733,\"channel\":\"channel-test\",\"data\":\"{\\\"type\\\" : \\\"CONTROL\\\", \\\"controlType\\\" : \\\"control-type-example\\\"}\",\"name\":\"asdasd\"}\n\n\r\n" }
  let(:event_invalid_format) { "fb\r\nid: 123\nevent: message\ndata: {\"id\":\"1\",\"clientId\":\"emptyClientId\",\"connectionId\":\"1\",\"timestamp\":1582045421733,\"channel\":\"channel-test\",\"content\":\"{\\\"type\\\" : \\\"SPLIT_UPDATE\\\",\\\"changeNumber\\\": 5564531221}\",\"name\":\"asdasd\"}\n\n\r\n" }
  let(:event_occupancy) { "d4\r\nevent: message\ndata: {\"id\":\"123\",\"timestamp\":1586803930362,\"encoding\":\"json\",\"channel\":\"[?occupancy=metrics.publishers]control_pri\",\"data\":\"{\\\"metrics\\\":{\\\"publishers\\\":2}}\",\"name\":\"[meta]occupancy\"}\n\n\r\n" }
  let(:event_error) { "d4\r\nevent: error\ndata: {\"message\":\"Token expired\",\"code\":40142,\"statusCode\":401,\"href\":\"https://help.ably.io/error/40142\"}" }

  it 'receive split update event' do
    mock_server do |server|
      server.setup_response('/') do |_, res|
        send_stream_content(res, event_split_update)
      end
      event_queue = Queue.new
      action_event = ''
      sse_client = subject.new(config, api_token, telemetry_runtime_producer, event_parser, notification_manager_keeper, notification_processor)

      connected = sse_client.start(server.base_uri)
      expect(connected).to eq(true)

      event_result = event_queue.pop
      expect(event_result.data['type']).to eq(SplitIoClient::SSE::EventSource::EventTypes::SPLIT_UPDATE)
      expect(event_result.data['changeNumber']).to eq(5_564_531_221)
      expect(event_result.channel).to eq('channel-test')
      expect(event_result.client_id).to eq('emptyClientId')
      expect(event_result.event_type).to eq('message')
      expect(sse_client.connected?).to eq(true)
      sleep(2)
      expect(action_event).to eq(SplitIoClient::Constants::PUSH_CONNECTED)

      sse_client.close

      expect(sse_client.connected?).to eq(false)
    end
  end

  it 'receive split kill event' do
    mock_server do |server|
      server.setup_response('/') do |_, res|
        send_stream_content(res, event_split_kill)
      end

      event_queue = Queue.new
      action_event = ''
      sse_client = subject.new(config, api_token, telemetry_runtime_producer, event_parser, notification_manager_keeper, notification_processor)

      connected = sse_client.start(server.base_uri)
      expect(connected).to eq(true)

      event_result = event_queue.pop
      expect(event_result.data['type']).to eq(SplitIoClient::SSE::EventSource::EventTypes::SPLIT_KILL)
      expect(event_result.data['changeNumber']).to eq(5_564_531_221)
      expect(event_result.data['defaultTreatment']).to eq('off')
      expect(event_result.data['splitName']).to eq('split-test')
      expect(event_result.channel).to eq('channel-test')
      expect(event_result.client_id).to eq('emptyClientId')
      expect(event_result.event_type).to eq('message')
      expect(sse_client.connected?).to eq(true)
      sleep(2)
      expect(action_event).to eq(SplitIoClient::Constants::PUSH_CONNECTED)

      sse_client.close

      expect(sse_client.connected?).to eq(false)
    end
  end

  it 'receive segment update event' do
    mock_server do |server|
      server.setup_response('/') do |_, res|
        send_stream_content(res, event_segment_update)
      end

      event_queue = Queue.new
      action_event = ''
      sse_client = subject.new(config, api_token, telemetry_runtime_producer, event_parser, notification_manager_keeper, notification_processor)

      connected = sse_client.start(server.base_uri)
      expect(connected).to eq(true)

      event_result = event_queue.pop
      expect(event_result.data['type']).to eq(SplitIoClient::SSE::EventSource::EventTypes::SEGMENT_UPDATE)
      expect(event_result.data['changeNumber']).to eq(5_564_531_221)
      expect(event_result.data['segmentName']).to eq('segment-test')
      expect(event_result.channel).to eq('channel-test')
      expect(event_result.client_id).to eq('emptyClientId')
      expect(event_result.event_type).to eq('message')
      expect(sse_client.connected?).to eq(true)
      sleep(2)
      expect(action_event).to eq(SplitIoClient::Constants::PUSH_CONNECTED)

      sse_client.close

      expect(sse_client.connected?).to eq(false)
    end
  end

  it 'receive control event' do
    mock_server do |server|
      server.setup_response('/') do |_, res|
        send_stream_content(res, event_control)
      end

      event_queue = Queue.new
      action_event = ''
      sse_client = subject.new(config, api_token, telemetry_runtime_producer, event_parser, notification_manager_keeper, notification_processor)

      connected = sse_client.start(server.base_uri)
      expect(connected).to eq(true)

      event_result = event_queue.pop
      expect(event_result.data['type']).to eq(SplitIoClient::SSE::EventSource::EventTypes::CONTROL)
      expect(event_result.data['controlType']).to eq('control-type-example')
      expect(event_result.channel).to eq('channel-test')
      expect(event_result.client_id).to eq('emptyClientId')
      expect(event_result.event_type).to eq('message')
      expect(sse_client.connected?).to eq(true)
      sleep(2)
      expect(action_event).to eq(SplitIoClient::Constants::PUSH_CONNECTED)

      sse_client.close

      expect(sse_client.connected?).to eq(false)
    end
  end

  it 'receive invalid format' do
    mock_server do |server|
      server.setup_response('/') do |_, res|
        send_stream_content(res, event_invalid_format)
      end

      event_queue = Queue.new
      action_event = ''
      sse_client = subject.new(config, api_token, telemetry_runtime_producer, event_parser, notification_manager_keeper, notification_processor)

      connected = sse_client.start(server.base_uri)
      expect(connected).to eq(true)

      sleep 0.5
      expect(event_queue.empty?).to be_truthy
      expect(sse_client.connected?).to eq(true)
      expect(action_event).to eq(SplitIoClient::Constants::PUSH_CONNECTED)

      sse_client.close

      expect(sse_client.connected?).to eq(false)
    end
  end

  it 'receive occupancy event' do
    mock_server do |server|
      server.setup_response('/') do |_, res|
        send_stream_content(res, event_occupancy)
      end

      event_queue = Queue.new
      action_event = ''
      sse_client = subject.new(config, api_token, telemetry_runtime_producer, event_parser, notification_manager_keeper, notification_processor)

      connected = sse_client.start(server.base_uri)
      expect(connected).to eq(true)

      event_result = event_queue.pop
      expect(event_result.data['metrics']['publishers']).to eq(2)
      expect(event_result.channel).to eq('control_pri')
      expect(event_result.client_id).to eq(nil)
      expect(event_result.event_type).to eq('message')
      expect(sse_client.connected?).to eq(true)
      sleep(2)
      expect(action_event).to eq(SplitIoClient::Constants::PUSH_CONNECTED)

      sse_client.close

      expect(sse_client.connected?).to eq(false)
    end
  end

  it 'receive error event' do
    mock_server do |server|
      server.setup_response('/') do |_, res|
        send_stream_content(res, event_error, 400)
      end

      event_queue = Queue.new
      sse_client = subject.new(config, api_token, telemetry_runtime_producer, event_parser, notification_manager_keeper, notification_processor)

      connected = sse_client.start(server.base_uri)

      expect(connected).to eq(false)
      expect(sse_client.connected?).to eq(false)
      expect(event_queue.empty?).to eq(true)

      # TODO: review failing in travis
      # sleep 5
      # events = telemetry_runtime_consumer.pop_streaming_events
      # expect(events.length).to be(1)
    end
  end

  it 'first event - when server return 400' do
    mock_server do |server|
      server.setup_response('/') do |_, res|
        send_stream_content(res, event_error, 400)
      end

      sse_client = subject.new(config, api_token, telemetry_runtime_producer, event_parser, notification_manager_keeper, notification_processor)

      connected = sse_client.start(server.base_uri)
      expect(connected).to eq(false)
    end
  end
end

private

def send_stream_content(res, content, status = 200)
  res.content_type = 'text/event-stream'
  res.status = status
  res.chunked = true
  rd, wr = IO.pipe
  wr.write(content)
  res.body = rd
  wr.close
  wr
end
