import Config
config :reception_desk, ReceptionDesk.Endpoint,
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  render_errors: [formats: [json: ReceptionDesk.Errors], layout: false],
  pubsub_server: ReceptionDesk.PubSub,
  secret_key_base: String.duplicate("local-reception-desk-development-", 3),
  server: true
config :phoenix, :json_library, Jason
