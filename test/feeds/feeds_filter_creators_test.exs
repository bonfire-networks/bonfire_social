defmodule Bonfire.Social.FeedsFilterCreatorsTest do
  @moduledoc """
  `creators` picks activities whose object one of the given people created, whatever the verb: their own posts, and also boosts and likes of those posts. It's how the Boosts chip shows boosts of the reader's posts, rather than every boost that reached them (a group's automatic boost of a member's post, brought by a bell on the group).

  Top-level posts only is not part of it: a caller that wants a person's posts without their replies excludes the `:reply` verb, since every reply is stored as `:reply`, as "User posts" does.
  """
  use Bonfire.Social.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Boosts
  alias Bonfire.Me.Fake
  import Bonfire.Posts.Fake

  setup do
    Process.put([:bonfire, :default_pagination_limit], 20)

    me = Fake.fake_user!()
    them = Fake.fake_user!()
    booster = Fake.fake_user!()

    my_post = fake_post!(me, "public", %{post_content: %{html_body: "a post of mine"}})
    their_post = fake_post!(them, "public", %{post_content: %{html_body: "a post of theirs"}})

    {:ok, _} = Boosts.boost(booster, my_post)
    {:ok, _} = Boosts.boost(booster, their_post)

    my_reply =
      fake_post!(me, "public", %{
        post_content: %{html_body: "a reply of mine"},
        reply_to_id: id(their_post)
      })

    {:ok, me: me, my_post: my_post, their_post: their_post, my_reply: my_reply}
  end

  defp feed(me, filters) do
    FeedLoader.feed(:custom, Map.merge(%{show_objects_only_once: false}, filters),
      current_user: me
    )
  end

  defp in?(feed, object, me), do: FeedLoader.feed_contains?(feed, object, current_user: me)

  test "without it, both boosts are there, so the filter is what picks", %{
    me: me,
    my_post: my_post,
    their_post: their_post
  } do
    boosts = feed(me, %{activity_types: [:boost]})

    assert in?(boosts, my_post, me)
    assert in?(boosts, their_post, me)
  end

  test "with boosts, it keeps a boost of my post and drops a boost of someone else's", %{
    me: me,
    my_post: my_post,
    their_post: their_post
  } do
    boosts = feed(me, %{activity_types: [:boost], creators: [id(me)]})

    assert in?(boosts, my_post, me)
    refute in?(boosts, their_post, me)
  end

  test "with posts, it keeps my own post", %{me: me, my_post: my_post, their_post: their_post} do
    posts = feed(me, %{activity_types: [:create], creators: [id(me)]})

    assert in?(posts, my_post, me)
    refute in?(posts, their_post, me)
  end

  # activity on that person's posts (a boost of one) may show there too, which is fine: what it leaves out is their replies, and anything about someone else's posts
  test "\"User posts\" shows that person's posts, not their replies", %{
    me: me,
    my_post: my_post,
    their_post: their_post,
    my_reply: my_reply
  } do
    # viewed by someone else, as a profile is
    viewer = Fake.fake_user!()

    posts =
      FeedLoader.feed(:user_by_object_type, %{show_objects_only_once: false},
        current_user: viewer,
        by: id(me)
      )

    assert in?(posts, my_post, viewer)
    refute in?(posts, my_reply, viewer)
    # someone else's post, and the boost of it, are not about this person's posts
    refute in?(posts, their_post, viewer)
  end
end
