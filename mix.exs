Code.eval_file("mess.exs")
defmodule Bonfire.Social.MixProject do
  use Mix.Project

  def project do
    [
      app: :bonfire_social,
      version: "0.1.0",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps: Mess.deps [
        {:bonfire_api_graphql, git: "https://github.com/bonfire-networks/bonfire_api_graphql", branch: "main", optional: true},
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end
end
