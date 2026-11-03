import Config
port = String.to_integer(System.get_env("PORT") || System.get_env("PARVI_BROKER_PORT") || "8765")
bind = System.get_env("PARVI_BROKER_BIND") || "127.0.0.1"
{:ok, ip} = :inet.parse_address(String.to_charlist(bind))
secret = System.get_env("SECRET_KEY_BASE") || if config_env() == :prod do
  raise "Set SECRET_KEY_BASE for production"
else
  String.duplicate("local-reception-desk-development-", 3)
end
config :reception_desk, ReceptionDesk.Endpoint,
  http: [ip: ip, port: port,
         transport_options: [socket_opts: [send_timeout: 5_000, send_timeout_close: true]]],
  secret_key_base: secret
