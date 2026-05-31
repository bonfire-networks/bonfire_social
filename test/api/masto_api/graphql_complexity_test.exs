# SPDX-License-Identifier: AGPL-3.0-only
if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.MastoApi.GraphqlComplexityTest do
    @moduledoc """
    Phase 3 (GRAPHQL_FIRST_MASTO_PLAN.md): the PUBLIC GraphQL endpoint enables complexity
    analysis (via `PlugPipelines.default_pipeline`) so abusive pagination/nesting is rejected
    before resolution; INTERNAL `Absinthe.run` reads (REST-on-GraphQL) don't enable it and so
    are not limited. These tests exercise the complexity functions + limit directly through
    `Absinthe.run(..., analyze_complexity: true)`, which is exactly what the public pipeline does.
    """
    use Bonfire.Social.MastoApiCase, async: true

    alias Bonfire.API.GraphQL.Schema

    @moduletag :masto_api

    @feed_query """
    query Feed($first: Int) {
      feedActivities(first: $first, filter: {feedName: "local"}) {
        edges { node { id object { ... on Post { id postContent { htmlBody } } } } }
      }
    }
    """

    defp complexity_error?(%{errors: errors}) when is_list(errors) do
      Enum.any?(errors, &(to_string(&1[:message] || &1["message"] || "") =~ "complex"))
    end

    defp complexity_error?(_), do: false

    test "an abusive `first` is rejected by complexity analysis (public pipeline behaviour)" do
      {:ok, result} =
        Absinthe.run(@feed_query, Schema,
          variables: %{"first" => 100_000},
          analyze_complexity: true,
          max_complexity: 8_000
        )

      assert complexity_error?(result),
             "expected a complexity error, got: #{inspect(result)}"
    end

    test "a normal page size passes complexity analysis" do
      {:ok, result} =
        Absinthe.run(@feed_query, Schema,
          variables: %{"first" => 20},
          analyze_complexity: true,
          max_complexity: 8_000,
          context: Schema.context(%{})
        )

      refute complexity_error?(result)
    end

    test "token_limit rejects an oversized document (lexer guard)" do
      # A tiny token ceiling rejects any real query at the lexer stage (before parse/resolution),
      # which is how the public pipeline blocks megabyte payloads.
      {:ok, result} =
        Absinthe.run(@feed_query, Schema, variables: %{"first" => 20}, token_limit: 5)

      assert match?(%{errors: errors} when is_list(errors) and errors != [], result),
             "expected a token-limit error, got: #{inspect(result)}"
    end

    test "internal Absinthe.run (no analyze_complexity) is NOT limited — abusive `first` still runs" do
      {:ok, result} =
        Absinthe.run(@feed_query, Schema,
          variables: %{"first" => 100_000},
          context: Schema.context(%{})
        )

      # No complexity analysis ⇒ no complexity error, even for a huge page size (this is the
      # internal REST-on-GraphQL path; trusted, fixed queries).
      refute complexity_error?(result)
    end
  end
end
