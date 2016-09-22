require 'spec_helper'

describe SplitIoClient::Cache::Stores::SplitStore do
  let(:adapter) { SplitIoClient::Cache::Adapters::MemoryAdapter.new }
  let(:splits_repository) { SplitIoClient::Cache::Repositories::SplitsRepository.new(adapter) }
  let(:config) { SplitIoClient::SplitConfig.new }
  let(:metrics) { SplitIoClient::Metrics.new(100) }
  let(:store) { described_class.new(splits_repository, config, '', metrics) }
  let(:active_splits_json) { File.read(File.expand_path(File.join(File.dirname(__FILE__), '../../test_data/splits/splits.json'))) }
  let(:archived_splits_json) { File.read(File.expand_path(File.join(File.dirname(__FILE__), '../../test_data/splits/splits2.json'))) }

  before do
    stub_request(:get, 'https://sdk.split.io/api/splitChanges?since=-1')
      .to_return(status: 200, body: active_splits_json)
  end

  it 'returns splits since' do
    splits = store.send(:splits_since, -1)

    expect(splits[:splits].count).to eq(2)
  end

  it 'stores data in the cache' do
    store.send(:store_splits)

    expect(store.splits_repository['splits'].size).to eq(2)
    expect(store.splits_repository.get_change_number).to eq(store.send(:splits_since, -1)[:till])
  end

  it 'refreshes splits' do
    store.send(:store_splits)

    active_split = store.splits_repository['splits']['test_1_ruby']
    expect(active_split[:status]).to eq('ACTIVE')

    stub_request(:get, 'https://sdk.split.io/api/splitChanges?since=1473413807667')
      .to_return(status: 200, body: archived_splits_json)

    store.send(:store_splits)

    archived_split = store.splits_repository['splits']['test_1_ruby']
    expect(archived_split[:status]).to eq('ARCHIVED')
  end
end
