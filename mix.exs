defmodule MOQX.MixProject do
  use Mix.Project

  def project do
    [
      app: :moqx,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test, "test.integration": :test]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.37.1", runtime: false},
      {:jose, "~> 1.11"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      ci: ["format --check-formatted", "credo --strict", "test --exclude integration"],
      "test.integration": ["test --only integration"]
    ]
  end
end
