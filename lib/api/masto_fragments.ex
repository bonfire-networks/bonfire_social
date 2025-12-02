if Application.compile_env(:bonfire, :modularity) != :disabled and
     Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.MastoFragments do
    @moduledoc "GraphQL fragments for Mastodon API post/status mapping."

    @post_content """
      name
      summary
      content: html_body
    """

    def post_content, do: @post_content
  end
end
