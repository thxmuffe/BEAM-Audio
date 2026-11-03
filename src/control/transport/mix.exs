defmodule ParviTransport.MixProject do
  # Dependency build only. Parvi's connection workers live in src/control/src/*.erl.
  use Mix.Project
  def project do
    [app: :parvi_transport, version: "0.1.0", elixir: "~> 1.19",
     build_path: "../../../builds/intermediates/BeamTransport",
     deps_path: "../../../builds/intermediates/BeamTransportDeps",
     deps: [{:ex_webrtc, "0.17.0"}, {:ex_sctp, "0.1.3"}]]
  end
  def application, do: [extra_applications: [:logger]]
end
