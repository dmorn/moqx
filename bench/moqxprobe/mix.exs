defmodule MOQXProbe.MixProject do
  use Mix.Project

  def project do
    [
      app: :moqxprobe,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :telemetry]
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
      {:flow, "~> 1.2"},
      {:gen_stage, "~> 1.3"},
      {:telemetry_metrics, "~> 1.1"},
      {:benchee, "~> 1.5", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
