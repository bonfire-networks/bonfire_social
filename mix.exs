Code.eval_file("mess.exs", (if File.exists?("../../lib/mix/mess.exs"), do: "../../lib/mix/"))

defmodule Bonfire.Social.MixProject do
  use Mix.Project

  def project do
    if File.exists?("../../.is_umbrella.exs") do
      [
        build_path: "../../_build",
        config_path: "../../config/config.exs",
        deps_path: "../../deps",
        lockfile: "../../mix.lock"
      ]
    else
      []
    end
    ++
    [
      app: :bonfire_social,
      version: "0.1.0",
      elixir: "~> 1.11",
      start_permanent: Mix.env() == :prod,
      deps:
        Mess.deps([
          {:bonfire_me,
           git: "https://github.com/bonfire-networks/bonfire_me",
           branch: "main",
           optional: true},
          {:bonfire_api_graphql,
           git: "https://github.com/bonfire-networks/bonfire_api_graphql",
           branch: "main",
           optional: true},
          {:absinthe, "~> 1.7", optional: true}
        ])
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application, do: [extra_applications: [:logger]]
end
