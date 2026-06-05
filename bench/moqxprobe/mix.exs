defmodule MOQXProbe.MixProject do
  use Mix.Project

  def project do
    [
      app: :moqxprobe,
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
      mod: {MOQXProbe.Application, []}
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
      {:moqx, path: "../.."},
      {:burrito, "~> 1.5"},
      {:flow, "~> 1.2"},
      {:gen_stage, "~> 1.3"},
      {:telemetry_metrics, "~> 1.1"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp releases do
    [
      moqxprobe_runtime: [
        include_erts: true,
        include_executables_for: [:unix],
        applications: [
          moqxprobe: :permanent
        ]
      ],
      moqxprobe_burrito: [
        steps: [:assemble, &Burrito.wrap/1],
        applications: [
          moqxprobe: :permanent
        ],
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
