# SPDX-License-Identifier: Apache-2.0
#
#  The OpenSearch Contributors require contributions made to
#  this file be licensed under the Apache-2.0 license or a
#  compatible open source license.
#
#  Modifications Copyright OpenSearch Contributors. See
#  GitHub history for details.

require_relative "../../../spec/opensearch_spec_helper"

describe "index template expected behavior", :integration => true do
  subject! do
    require "logstash/outputs/opensearch"
    settings = {
      "manage_template" => true,
      "template_overwrite" => true,
      "hosts" => "#{get_host_port()}"
    }
    next LogStash::Outputs::OpenSearch.new(settings)
  end

  before :each do
    # Delete all templates first.
    require "elasticsearch"

    # Clean OpenSearch of data before we start.
    @client = get_client
    @client.indices.delete_template(:name => "*")

    # This can fail if there are no indexes, ignore failure.
    @client.indices.delete(:index => "*") rescue nil

    subject.register

    subject.multi_receive([
      LogStash::Event.new("message" => "sample message here"),
      LogStash::Event.new("somemessage" => { "message" => "sample nested message here" }),
      LogStash::Event.new("somevalue" => 100),
      LogStash::Event.new("somevalue" => 10),
      LogStash::Event.new("somevalue" => 1),
      LogStash::Event.new("country" => "us"),
      LogStash::Event.new("country" => "at"),
      LogStash::Event.new("geoip" => { "location" => [ 0.0, 0.0 ] })
    ])

    @client.indices.refresh

    # Wait or fail until everything's indexed.
    Stud::try(20.times) do
      r = @client.search(index: 'logstash-*')
      expect(r).to have_hits(8)
    end
  end

  it "permits phrase searching on string fields" do
    results = @client.search(:q => "message:\"sample message\"")
    expect(results).to have_hits(1)
    expect(results["hits"]["hits"][0]["_source"]["message"]).to eq("sample message here")
  end

  it "numbers dynamically map to a numeric type and permit range queries" do
    results = @client.search(:q => "somevalue:[5 TO 105]")
    expect(results).to have_hits(2)

    values = results["hits"]["hits"].collect { |r| r["_source"]["somevalue"] }
    expect(values).to include(10)
    expect(values).to include(100)
    expect(values).to_not include(1)
  end

  it "does not create .keyword field for top-level message field" do
    results = @client.search(:q => "message.keyword:\"sample message here\"")
    expect(results).to have_hits(0)
  end

  it "creates .keyword field for nested message fields" do
    results = @client.search(:q => "somemessage.message.keyword:\"sample nested message here\"")
    expect(results).to have_hits(1)
  end

  it "creates .keyword field from any string field which is not_analyzed" do
    results = @client.search(:q => "country.keyword:\"us\"")
    expect(results).to have_hits(1)
    expect(results["hits"]["hits"][0]["_source"]["country"]).to eq("us")

    # partial or terms should not work.
    results = @client.search(:q => "country.keyword:\"u\"")
    expect(results).to have_hits(0)
  end

  it "make [geoip][location] a geo_point" do
    expect(field_properties_from_template("logstash", "geoip")["location"]["type"]).to eq("geo_point")
  end

  it "aggregate .keyword results correctly " do
    results = @client.search(:body => { "aggregations" => { "my_agg" => { "terms" => { "field" => "country.keyword" } } } })["aggregations"]["my_agg"]
    terms = results["buckets"].collect { |b| b["key"] }

    expect(terms).to include("us")

    # 'at' is a stopword, make sure stopwords are not ignored.
    expect(terms).to include("at")
  end
end
