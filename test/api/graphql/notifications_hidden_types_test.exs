if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled do
  defmodule Bonfire.Social.API.GraphQL.NotificationsHiddenTypesTest do
    @moduledoc """
    A GraphQL client asking for someone's notifications gets them as that user configured them.

    The saved "Show in Latest" categories apply by default, in the shape of Mastodon's
    `include_filtered`: server-side unless the caller asks for everything, which is what
    `includeHiddenTypes` is for and what the Mastodon adapter passes.
    """
    use Bonfire.Social.DataCase, async: false

    alias Bonfire.API.GraphQL.Schema
    alias Bonfire.Common.Settings
    alias Bonfire.Social.Notifications

    @moduletag :graphql

    @query """
    query Notifications($includeHidden: Boolean) {
      feed: feedActivitiesPreloaded(first: 10, filter: {feed_name: "notifications", include_hidden_types: $includeHidden}) {
        edges { node { id verb { verb } } }
      }
    }
    """

    setup do
      me = Bonfire.Me.Fake.fake_user!()

      {:ok, post} =
        Bonfire.Posts.publish(
          current_user: me,
          post_attrs: %{post_content: %{html_body: "a post of mine to react to"}},
          boundary: "public"
        )

      other = Bonfire.Me.Fake.fake_user!()
      {:ok, _} = Bonfire.Social.Likes.like(other, post)
      {:ok, _} = Bonfire.Social.Boosts.boost(other, post)

      {:ok,
       me:
         Settings.put(Notifications.show_in_centre_key(:boost), false, current_user: me)
         |> current_user()}
    end

    defp verbs(user, variables) do
      {:ok, result} =
        Absinthe.run(@query, Schema,
          variables: variables,
          context: Schema.context(%{current_user: user})
        )

      refute result[:errors]

      get_in(result, [:data, "feed", "edges"])
      |> Enum.map(&get_in(&1, ["node", "verb", "verb"]))
      |> Enum.sort()
    end

    test "the hidden category is left out by default", %{me: me} do
      assert verbs(me, %{}) == ["Like"]
    end

    test "a client can ask for everything", %{me: me} do
      assert verbs(me, %{"includeHidden" => true}) == ["Boost", "Like"]
    end
  end
end
