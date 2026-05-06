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
      preferred_envs: [ci: :test]
    ]
  end

  defp deps do
    [
      {:quicer,
       git: "https://github.com/dmorn/quic.git", branch: "fix/macos-cmake-arch-detection"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false}
    ]
  end

  defp description do
    "Elixir Media over QUIC transport library targeting MOQT draft-14."
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
