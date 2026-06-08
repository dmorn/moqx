defmodule Probed.MixProject do
  use Mix.Project

  def project do
    [
      app: :probed,
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
      extra_applications: [:logger],
      mod: {Probed.Application, []}
    ]
  end

  defp aliases do
    [
      ci: ["format --check-formatted", "credo --strict", "test"]
    ]
  end

  defp deps do
    [
      {:probe_ledger, path: "../ledger"},
      {:bandit, "~> 1.11"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.19"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      probed: [
        include_erts: true,
        include_executables_for: [:unix],
        applications: [probed: :permanent]
      ]
    ]
  end
end
