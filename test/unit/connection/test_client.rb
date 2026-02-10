require_relative "../../test_helper"

module Unit
  module Connection
    class TestClient < Minitest::Test
      EMPTY_JSON = '{"rows":0,"data":[],"meta":[],"statistics":{"elapsed":0.001,"rows_read":0,"bytes_read":0}}'

      class Connection < SimpleConnection
        include Clickhouse::Connection::Client
      end

      describe Clickhouse::Connection::Client do
        before do
          @connection = Connection.new
          @connection.stubs(:parse_stats)
          @connection.stubs(:write_log)
        end

        describe "#connect!" do
          describe "when failed to connect" do
            it "returns true" do
              Faraday::Connection.any_instance.expects(:get).raises(Faraday::ConnectionFailed.new("Failed to connect"))
              assert_raises Clickhouse::ConnectionError do
                @connection.connect!
              end
            end
          end

          describe "when receiving 200" do
            it "returns true" do
              Faraday::Connection.any_instance.expects(:get).returns(stub(:status => 200))
              assert_equal true, @connection.connect!
            end
          end

          describe "when receiving 500" do
            it "raises a Clickhouse::ConnectionError" do
              Faraday::Connection.any_instance.expects(:get).returns(stub(:status => 500))
              assert_raises Clickhouse::ConnectionError do
                @connection.connect!
              end
            end
          end

          describe "when already connected" do
            it "returns nil" do
              @connection.instance_variable_set :@client, mock
              assert_nil @connection.connect!
            end
          end
        end

        describe "#connected?" do
          it "returns whether it has an connected socket" do
            assert_equal false, @connection.connected?
            @connection.instance_variable_set :@client, mock
            assert_equal true, @connection.connected?
            @connection.instance_variable_set :@client, nil
            assert_equal false, @connection.connected?
          end
        end

        describe "#get" do
          it "sends a GET request the server" do
            @connection.instance_variable_set :@client, (client = mock)
            client.expects(:get).with("/?query=foo&output_format_write_statistics=1", nil).yields(stub(:headers => {})).returns(stub(:status => 200, :body => EMPTY_JSON))
            @connection.stubs(:log)
            @connection.stubs(:parse_body).returns({})
            @connection.get("foo")
          end
        end

        describe "#post" do
          it "sends a POST request the server" do
            @connection.instance_variable_set :@client, (client = mock)
            client.expects(:post).with("/?query=foo&output_format_write_statistics=1", "body").yields(stub(:headers => {})).returns(stub(:status => 200, :body => EMPTY_JSON))
            @connection.stubs(:log)
            @connection.stubs(:parse_body).returns({})
            @connection.post("foo", "body")
          end
        end

        describe "#request" do
          before do
            @connection.stubs(:log)
          end

          it "connects to the server first" do
            @connection.instance_variable_set :@client, (client = mock)
            @connection.expects(:connect!)
            @connection.stubs(:parse_body).returns({})
            client.stubs(:get).yields(stub(:headers => {})).returns(stub(:status => 200, :body => EMPTY_JSON))
            @connection.send :request, :get, "/", "query"
          end

          it "queries the server returning the response" do
            @connection.instance_variable_set :@client, (client = mock)
            client.expects(:get).with("/?query=SELECT+1&output_format_write_statistics=1", nil).yields(stub(:headers => {})).returns(stub(:status => 200, :body => ""))
            @connection.expects(:parse_body).returns(data = {})
            assert_equal data, @connection.send(:request, :get, "SELECT 1")
          end

          describe "when not receiving status 200" do
            it "raises a Clickhouse::QueryError" do
              @connection.instance_variable_set :@client, (client = mock)
              client.expects(:get).with("/?query=SELECT+1&output_format_write_statistics=1", nil).yields(stub(:headers => {})).returns(stub(:status => 500, :body => ""))
              assert_raises Clickhouse::QueryError do
                @connection.send(:request, :get, "SELECT 1")
              end
            end
          end

          describe "when getting Faraday::Error" do
            it "raises a Clickhouse::ConnectionError" do
              @connection.instance_variable_set :@client, (client = mock)
              client.expects(:get).raises(Faraday::ConnectionFailed.new("Failed to connect"))
              assert_raises Clickhouse::ConnectionError do
                @connection.send(:request, :get, "SELECT 1")
              end
            end
          end

          it "parses the body" do
            json = <<-JSON
              {"meta": []}
            JSON
            @connection.instance_variable_set :@client, (client = mock)
            client.expects(:get).with("/?query=SELECT+1+FORMAT+JSONCompact&output_format_write_statistics=1", nil).yields(stub(:headers => {})).returns(stub(:status => 200, :body => json))
            result = @connection.send(:request, :get, "SELECT 1 FORMAT JSONCompact")
            assert_equal [], result["meta"]
          end
        end

        describe "configuration" do
          describe "database" do
            it "includes the database in the querystring" do
              @connection.instance_variable_get(:@config)[:database] = "system"
              @connection.instance_variable_set(:@client, (client = mock))
              client.expects(:get).with("/?database=system&query=SELECT+1&output_format_write_statistics=1", nil).yields(stub(:headers => {})).returns(stub(:status => 200, :body => ""))
              @connection.expects(:parse_body).returns(data = {})
              assert_equal data, @connection.send(:request, :get, "SELECT 1")
            end
          end

          describe "authentication" do
            it "includes the credentials in the request headers" do
              Faraday::Connection.any_instance.expects(:get).returns(stub(status: 200))
              connection = Clickhouse::Connection.new :password => "awesomepassword"
              connection.connect!
              assert_equal "Basic ZGVmYXVsdDphd2Vzb21lcGFzc3dvcmQ=", connection.send(:client).headers["Authorization"].force_encoding("UTF-8")
            end
          end
        end

        describe "statistics" do
          before do
            @connection = Connection.new
            @json = <<-JSON
              {
                "rows": 1947,
                "statistics": {
                  "elapsed": 0.1882,
                  "rows_read": 1982,
                  "bytes_read": 2003
                }
              }
            JSON
          end

          it "parses the statistics" do
            @connection.stubs(:log)
            @connection.instance_variable_set :@client, (client = mock)
            Time.stubs(:now).returns(1882)

            client.expects(:get).with("/?query=SELECT+1+FORMAT+JSONCompact&output_format_write_statistics=1", nil).yields(stub(:headers => {})).returns(stub(:status => 200, :body => @json))
            @connection.expects(:write_log).with(
              0, "SELECT 1", {
                "elapsed" => "188.2ms",
                "rows_read" => "1.98 thousand",
                "bytes_read" => 2003,
                "rows" => 1947,
                "rows_per_second" => "10.53 thousand",
                "data_per_second" => "10.39 KB",
                "data_read" => "1.96 KB"
              }
            )
            @connection.send(:request, :get, "SELECT 1 FORMAT JSONCompact")
          end

          it "write the expected logs" do
            @connection.instance_variable_set :@client, (client = mock)
            Time.stubs(:now).returns(1882)

            client.expects(:get).with("/?query=SELECT+1+FORMAT+JSONCompact&output_format_write_statistics=1", nil).yields(stub(:headers => {})).returns(stub(:status => 200, :body => @json))
            log = "\n \e[1m\e[35mSQL (0.0ms)\e\e[0m  SELECT 1;\e\n  \e[1m\e[36m1947 rows in set. Elapsed: 188.2ms. Processed: 1.98 thousand rows, 1.96 KB (10.53 thousand rows/s, 10.39 KB/s)\e[0m "

            @connection.expects(:log).with(:debug, log)
            @connection.send(:request, :get, "SELECT 1 FORMAT JSONCompact")
          end

          describe "#number_to_human_duration" do
            it "returns in seconds when more than 1 seconds" do
              assert_equal "2s", @connection.send(:number_to_human_duration, 2)
            end
          end
        end

        describe "#resolve_headers" do
          it "returns empty hash when headers config is nil" do
            @connection.instance_variable_get(:@config).delete(:headers)
            assert_equal({}, @connection.resolve_headers)
          end

          it "returns the hash when headers config is a Hash" do
            headers = {"X-Custom-Header" => "value"}
            @connection.instance_variable_get(:@config)[:headers] = headers
            assert_equal headers, @connection.resolve_headers
          end

          it "calls the proc and returns result when headers config is a Proc" do
            headers = {"X-Dynamic-Header" => "dynamic-value"}
            @connection.instance_variable_get(:@config)[:headers] = -> { headers }
            assert_equal headers, @connection.resolve_headers
          end

          it "returns empty hash when proc returns nil" do
            @connection.instance_variable_get(:@config)[:headers] = -> { nil }
            assert_equal({}, @connection.resolve_headers)
          end
        end

        describe "headers in requests" do
          def json_response
            '{"rows":0,"data":[],"meta":[],"statistics":{"elapsed":0.001,"rows_read":0,"bytes_read":0}}'
          end

          def connection_with_stubs(headers_config:, &block)
            captured_headers = nil

            stubs = Faraday::Adapter::Test::Stubs.new do |stub|
              stub.get(/.*/) do |env|
                captured_headers = env.request_headers.to_h
                [200, {}, json_response]
              end
              stub.post(/.*/) do |env|
                captured_headers = env.request_headers.to_h
                [200, {}, json_response]
              end
            end

            clickhouse = Clickhouse::Connection.new(url: "http://localhost:8123", headers: headers_config)
            faraday_client = Faraday.new(url: "http://localhost:8123") { |f| f.adapter :test, stubs }
            clickhouse.instance_variable_set(:@client, faraday_client)

            yield clickhouse, -> { captured_headers }
          end

          describe "GET request" do
            it "sends headers from Hash config to the server" do
              connection_with_stubs(headers_config: {"X-Test" => "test-value"}) do |clickhouse, get_headers|
                clickhouse.query("SELECT 1 FORMAT JSON")
                assert_equal "test-value", get_headers.call["X-Test"]
              end
            end

            it "sends headers from Proc config to the server" do
              call_count = 0
              headers_proc = -> {
                call_count += 1
                {"X-Dynamic" => "value-#{call_count}"}
              }

              connection_with_stubs(headers_config: headers_proc) do |clickhouse, get_headers|
                clickhouse.query("SELECT 1 FORMAT JSON")
                assert_equal "value-1", get_headers.call["X-Dynamic"]

                clickhouse.query("SELECT 2 FORMAT JSON")
                assert_equal "value-2", get_headers.call["X-Dynamic"]
              end
            end
          end

          describe "POST request" do
            it "sends headers from config to the server" do
              connection_with_stubs(headers_config: {"X-Post-Header" => "post-value"}) do |clickhouse, get_headers|
                clickhouse.query_post("SELECT 1 FORMAT JSON")
                assert_equal "post-value", get_headers.call["X-Post-Header"]
              end
            end
          end
        end
      end
    end
  end
end
