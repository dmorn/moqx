defmodule MOQX.TransportBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :moqx_transport_bench,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      releases: releases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :telemetry],
      mod: {MOQX.TransportBench.Application, []}
    ]
  end

  defp aliases do
    [
      ci: ["format --check-formatted", "credo --strict", "test"]
    ]
  end

  defp deps do
    [
      {:moqx, path: "../.."},
      {:telemetry_metrics, "~> 1.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      moqx_transport_bench: [
        include_erts: true,
        include_executables_for: [:unix],
        applications: [
          moqx_transport_bench: :permanent
        ]
      ]
    ]
  end
end
