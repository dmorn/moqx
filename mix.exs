defmodule MOQX.MixProject do
  use Mix.Project

  def project do
    [
      app: :moqx,
      version: "0.1.0",
      description: description(),
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/dmorn/moqx",
      homepage_url: "https://github.com/dmorn/moqx",
      package: package(),
      docs: docs(),
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
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Elixir MOQ client bindings over Rustler NIFs with split publisher/subscriber sessions."
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["dmorn"],
      links: %{
        "Changelog" => "https://github.com/dmorn/moqx/blob/main/CHANGELOG.md",
        "GitHub" => "https://github.com/dmorn/moqx"
      },
      files: ~w(lib native priv mix.exs mix.lock README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "docs/relay-experiments.md"]
    ]
  end

  defp aliases do
    [
      ci: ["format --check-formatted", "credo --strict", "test --exclude integration"],
      "test.integration": ["test --only integration"]
    ]
  end
end
