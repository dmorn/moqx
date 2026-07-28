defmodule MOQX.MixProject do
  use Mix.Project

  def project do
    [
      app: :moqx,
      version: "0.7.1",
      description: description(),
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      source_url: "https://github.com/dmorn/moqx",
      homepage_url: "https://github.com/dmorn/moqx",
      package: package(),
      docs: docs(),
      aliases: aliases(),
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env())
    ]
  end

  def application do
    [
      extra_applications: [:logger, :telemetry]
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:telemetry, "~> 1.4"},
      {:quicer,
       git: "https://github.com/dmorn/quic.git", branch: "fix/dgram-send-state-feedback"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Elixir Media over QUIC transport library targeting MOQT drafts 14 and 16."
  end

  defp package do
    [
      licenses: ["MIT"],
      maintainers: ["dmorn"],
      links: %{
        "Changelog" => "https://github.com/dmorn/moqx/blob/main/CHANGELOG.md",
        "GitHub" => "https://github.com/dmorn/moqx"
      },
      files: ~w(lib mix.exs mix.lock README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp aliases do
    [
      ci: ["format --check-formatted", "credo --strict", "test"]
    ]
  end
end
