defmodule ProbeLedger.MixProject do
  use Mix.Project

  def project do
    [
      app: :probe_ledger,
      version: "0.1.0",
      elixir: "~> 1.19",
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp aliases do
    [
      ci: ["format --check-formatted", "credo --strict", "test"]
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end
end
