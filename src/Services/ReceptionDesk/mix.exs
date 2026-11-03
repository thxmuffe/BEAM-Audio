defmodule ReceptionDesk.MixProject do
  use Mix.Project
  def project do
    [app: :reception_desk, version: "0.2.0", elixir: "~> 1.19",
     build_path: "../../../builds/intermediates/ReceptionDeskMix",
     deps_path: "../../../builds/intermediates/ReceptionDeskDeps",
     erlc_paths: ["relay_src"], erlc_options: [:debug_info, :warnings_as_errors],
     deps: [{:phoenix, "1.8.16"}, {:plug_cowboy, "~> 2.8"},
            {:websock_adapter, "~> 0.5"}, {:jason, "~> 1.4"}, {:gun, "2.7.0"},
            {:cowlib, github: "ninenines/cowlib", ref: "4401b858f2229abb3ea115c60924f6c77e5f8aa3", override: true, manager: :rebar3}]]
  end
  def application, do: [mod: {ReceptionDesk.Application, []}, extra_applications: [:logger, :crypto]]
end
