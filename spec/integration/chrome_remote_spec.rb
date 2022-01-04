require "spec_helper"
require "oj"

RSpec.describe ChromeRemote do
  around(:each) do |example|
    # TODO should the library implement timeouts on every operation instead?
    Timeout::timeout(5) { example.run }
  end

  WS_URL = "ws://localhost:9222/devtools/page/4a64d04e-f346-4460-be97-98e4a3dbf2fc"

  before(:each) do
    stub_request(:get, "http://localhost:9222/json").to_return(
      body: Oj.to_json([{ "type": "page", "webSocketDebuggerUrl": WS_URL }])
    )
  end

  # Server needs to be running before the client
  let!(:server) { WebSocketTestServer.new(WS_URL) }
  let!(:client) { ChromeRemote.client }

  after(:each) { server.close }

  describe "Initializing a client" do
    it "returns a new client" do
      client = double("client")
      expect(ChromeRemote::Client).to receive(:new).with(WS_URL, nil) { client }
      expect(ChromeRemote.client).to eq(client)
    end

    it "uses the first page’s webSocketDebuggerUrl" do
      stub_request(:get, "http://localhost:9222/json").to_return(
        body: Oj.to_json([
          { "type": "background_page", "webSocketDebuggerUrl": "ws://one"   },
          { "type": "page",            "webSocketDebuggerUrl": "ws://two"   },
          { "type": "page",            "webSocketDebuggerUrl": "ws://three" }
        ])
      )

      expect(ChromeRemote::Client).to receive(:new).with("ws://two", nil)
      ChromeRemote.client
    end

    it "retries if no pages are returned" do
      request_count = 0
      stub_request(:get, "http://localhost:9222/json").to_return do |request|
        request_count += 1
        if request_count == 1
          { body: Oj.to_json([]) }
        else
          {
            body: Oj.to_json([
              { "type": "page", "webSocketDebuggerUrl": "ws://two" },
            ])
          }
        end
      end

      expect(ChromeRemote::Client).to receive(:new).with("ws://two", nil)
      ChromeRemote.client
    end

    it "gets pages from the given host and port" do
      stub_request(:get, "http://192.168.1.1:9292/json").to_return(
        body: Oj.to_json([{ "type": "page", "webSocketDebuggerUrl": "ws://one" }])
      )
      expect(ChromeRemote::Client).to receive(:new).with("ws://one", nil)
      ChromeRemote.client host: '192.168.1.1', port: 9292
    end

    it "accepts logger" do
      logger = double("logger")
      client = double("client")

      expect(ChromeRemote::Client).to receive(:new).with(WS_URL, logger) { client }
      expect(ChromeRemote.client(logger: logger)).to eq(client)
    end

    context "with new tab" do
      it "creates new tab on the given host and port" do
        stub_request(:get, "http://192.168.1.1:9292/json/new?about:blank").to_return(
          body: Oj.to_json({ "type": "page", "webSocketDebuggerUrl": "ws://one" })
        )
        expect(ChromeRemote::Client).to receive(:new).with("ws://one", nil)
        ChromeRemote.client host: '192.168.1.1', port: 9292, new_tab: true
      end
    end
  end

  describe "Logging" do
    let(:logger) { double("logger") }
    let!(:client) { ChromeRemote.client(logger: logger) }

    it "logs incoming and outcoming messages" do
      server.expect_msg do |msg|
        msg = Oj.load(msg)
        server.send_msg(Oj.to_json({ id: msg["id"], params: {} }))
      end

      expect(logger).to receive(:info).with('SEND ► {"method":"Page.enable","params":{},"id":1}')
      expect(logger).to receive(:info).with('◀ RECV {"id":1,"params":{}}')
      client.send_cmd('Page.enable')
    end
  end

  describe "Sending commands" do
    it "sends commands using the DevTools protocol" do
      expected_result = { "frameId" => rand(9999) }

      server.expect_msg do |msg|
        msg = Oj.load(msg)

        expect(msg["method"]).to eq("Page.navigate")
        expect(msg["params"]).to eq("url" => "https://github.com")
        expect(msg["id"]).to be_a(Integer)

        # Reply with two messages not correlating the msg["id"].
        # These two should be ignored by the client
        server.send_msg(Oj.to_json({ method: "RandomEvent" }))
        server.send_msg(Oj.to_json({ id: 9999, result: {} }))

        # Reply correlated with msg["id"]
        server.send_msg(Oj.to_json({ id: msg["id"],
                          result: expected_result }))
      end

      response = client.send_cmd "Page.navigate", url: "https://github.com"

      expect(response).to eq(expected_result)
      expect(server).to have_satisfied_all_expectations
    end
  end

  describe "Subscribing to events" do
    it "subscribes to events using the DevTools protocol" do
      received_events = []

      client.on "Network.requestWillBeSent" do |params|
        received_events << ["Network.requestWillBeSent", params]
      end

      client.on "Page.loadEventFired" do |params|
        received_events << ["Page.loadEventFired", params]
      end

      server.send_msg(Oj.to_json({ method: "RandomEvent" })) # to be ignored
      server.send_msg(Oj.to_json({ method: "Network.requestWillBeSent", params: { "param" => 1} }))
      server.send_msg(Oj.to_json({ id: 999, result: { "frameId" => 2 } })) # to be ignored
      server.send_msg(Oj.to_json({ method: "Page.loadEventFired",       params: { "param" => 2} }))
      server.send_msg(Oj.to_json({ method: "Network.requestWillBeSent", params: { "param" => 3} }))

      expect(received_events).to be_empty # we haven't listened yet

      client.listen_until { received_events.size == 3 }

      expect(received_events).to eq([
        ["Network.requestWillBeSent", { "param" => 1}],
        ["Page.loadEventFired",       { "param" => 2}],
        ["Network.requestWillBeSent", { "param" => 3}],
      ])
    end

    it "allows to subscribe multiple times to the same event" do
      received_events = []

      client.on "Network.requestWillBeSent" do |params|
        received_events << :first_handler
      end

      client.on "Network.requestWillBeSent" do |params|
        received_events << :second_handler
      end

      expect(received_events).to be_empty # we haven't listened yet

      server.send_msg(Oj.to_json({ method: "Network.requestWillBeSent" }))

      client.listen_until { received_events.size == 2 }

      expect(received_events).to include(:first_handler)
      expect(received_events).to include(:second_handler)
    end

    it "processes events when sending commands" do
      received_events = []

      client.on "Network.requestWillBeSent" do |params|
        received_events << :first_handler
      end

      server.expect_msg do |msg|
        msg = Oj.load(msg)
        server.send_msg(Oj.to_json({ method: "Network.requestWillBeSent" }))
        server.send_msg(Oj.to_json({ id: msg["id"] }))
      end

      expect(received_events).to be_empty # we haven't listened yet

      client.send_cmd "Page.navigate"

      expect(received_events).to eq([:first_handler])
    end

    it "subscribes to events and process them indefinitely" do
      expected_events = rand(10) + 1
      received_events = 0

      TestError = Class.new(StandardError)

      client.on "Network.requestWillBeSent" do |params|
        received_events += 1
        # the client will listen indefinitely, raise an expection to get out of the loop
        raise TestError if received_events == expected_events
      end

      expected_events.times do
        server.send_msg(Oj.to_json({ method: "Network.requestWillBeSent" }))
      end

      expect(received_events).to be_zero # we haven't listened yet

      expect{client.listen}.to raise_error(TestError)

      expect(received_events).to be(expected_events)
    end
  end

  describe "Waiting for events" do
    it "waits for the next instance of an event" do
      # first two messages are to be ignored
      server.send_msg(Oj.to_json({ id: 99 }))
      server.send_msg(Oj.to_json({ method: "Network.requestWillBeSent", params: { "event" => 1 } }))
      server.send_msg(Oj.to_json( method: "Page.loadEventFired",       params: { "event" => 2 } }))
      server.send_msg(Oj.to_json({ method: "Network.requestWillBeSent", params: { "event" => 3 } }))

      result = client.wait_for("Page.loadEventFired")
      expect(result).to eq({ "event" => 2 })

      result = client.wait_for("Network.requestWillBeSent")
      expect(result).to eq({ "event" => 3 })
    end

    it "subscribes and waits for the same event" do
      received_events = 0

      client.on "Network.requestWillBeSent" do |params|
        received_events += 1
      end

      server.send_msg(Oj.to_json({ method: "Network.requestWillBeSent" }))

      expect(received_events).to be_zero # we haven't listened yet

      result = client.wait_for("Network.requestWillBeSent")
      expect(received_events).to eq(1)
    end

    it "waits for events with custom matcher block" do
      server.send_msg(Oj.to_json({ method: "Page.lifecycleEvent", params: { "name" => "load" }}))
      server.send_msg(Oj.to_json({ method: "Page.lifecycleEvent", params: { "name" => "DOMContentLoaded" }}))
      result = client.wait_for do |event_name, event_params|
        event_name == "Page.lifecycleEvent" && event_params["name"] == "DOMContentLoaded"
      end

      expect(result).to eq({"name" => "DOMContentLoaded"})
    end
  end
end
