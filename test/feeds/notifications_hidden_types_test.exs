defmodule Bonfire.Social.Feeds.NotificationsHiddenTypesTest do
  @moduledoc """
  A category switched off in preferences is left out of any notifications read, not just the web UI's.

  `FeedLoader` applies it where a notifications read resolves its preset, so the LiveView, the
  GraphQL API and anything else asking for the feed answer the same way. Two escapes: a caller
  asking for everything (`include_hidden`), and a caller naming the types it wants, which outranks a
  preference about what to show by default.
  """
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Posts
  alias Bonfire.Social.Boosts
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Likes
  alias Bonfire.Social.Notifications
  alias Bonfire.Common.Settings
  alias Bonfire.Me.Fake

  setup do
    me = Fake.fake_user!()
    other = Fake.fake_user!()

    {:ok, post} =
      Posts.publish(
        current_user: me,
        post_attrs: %{post_content: %{html_body: "a post of mine to react to"}},
        boundary: "public"
      )

    {:ok, _} = Likes.like(other, post)
    {:ok, _} = Boosts.boost(other, post)

    {:ok, me: me}
  end

  # by verb id, since the rows carry one whether or not the verb itself was preloaded
  defp verbs(user, filters \\ %{}, opts \\ []) do
    %{edges: edges} =
      FeedLoader.feed(:notifications, filters, [current_user: user, limit: 100] ++ opts)

    verbs_of(edges)
  end

  defp verbs_of(edges) do
    edges
    |> Enum.map(&(e(&1, :activity, :verb_id, nil) || e(&1, :verb_id, nil)))
    |> Enum.map(&Verbs.get_slug/1)
    |> Enum.sort()
  end

  test "both reactions arrive until one is switched off", %{me: me} do
    assert verbs(me) == [:boost, :like]

    me =
      Settings.put(Notifications.show_in_centre_key(:boost), false, current_user: me)
      |> current_user()

    assert verbs(me) == [:like]
  end

  test "a caller can ask for everything", %{me: me} do
    me =
      Settings.put(Notifications.show_in_centre_key(:boost), false, current_user: me)
      |> current_user()

    assert verbs(me, %{}, include_hidden: true) == [:boost, :like]
  end

  test "asking for a switched-off type by name still returns it", %{me: me} do
    me =
      Settings.put(Notifications.show_in_centre_key(:boost), false, current_user: me)
      |> current_user()

    assert verbs(me, %{activity_types: [:boost]}) == [:boost]
  end

  test "a sibling category's read is unaffected", %{me: me} do
    me =
      Settings.put(Notifications.show_in_centre_key(:boost), false, current_user: me)
      |> current_user()

    # the exclusion is still in the query here, and harmless, since the read already asked for likes only
    assert verbs(me, %{activity_types: [:like]}) == [:like]
  end

  test "another feed is untouched by the preference", %{me: me} do
    me =
      Settings.put(Notifications.show_in_centre_key(:boost), false, current_user: me)
      |> current_user()

    %{edges: edges} = FeedLoader.feed(:my, %{}, current_user: me, limit: 100)

    assert :boost in verbs_of(edges)
  end
end
