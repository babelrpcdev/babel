defmodule Babel.MixProject do
  use Mix.Project

  def project do
    [
      app: :babel,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :runtime_tools],
      mod: {Babel.Application, []}
    ]
  end

  defp deps do
    [
      {:plug_cowboy, "~> 2.6"},
      {:jason, "~> 1.4"},
      {:httpoison, "~> 2.2"},
      {:websockex, "~> 0.4.3"},
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 0.6"},
      {:telemetry_poller, "~> 1.0"},
      {:prometheus_ex, "~> 3.1"},
      {:prometheus_plugs, "~> 1.1"},
      {:grpc, "~> 0.5"}
    ]
  end
end

