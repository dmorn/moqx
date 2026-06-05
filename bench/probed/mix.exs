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
      {:burrito, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.19"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      probed: [
        applications: [probed: :permanent]
      ],
      probed_burrito: [
        steps: [:assemble, &Burrito.wrap/1],
        applications: [probed: :permanent],
        burrito: [
          targets: [
            darwin_arm64: [os: :darwin, cpu: :aarch64],
            linux_arm64: [os: :linux, cpu: :aarch64],
            linux_x86_64: [os: :linux, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end
end
