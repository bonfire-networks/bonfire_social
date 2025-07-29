defmodule Bonfire.Social.FeedsMergingActivitiesTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake
  import Ecto.Query

  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Feeds
  alias Bonfire.Posts
  alias Needle.Pointer

  setup_all do
    orig2 = Config.get(:default_pagination_limit)

    Config.put(:default_pagination_limit, 10)

    on_exit(fn ->
      Config.put(:default_pagination_limit, orig2)
    end)
  end

  test "notifications feed combines likes and boosts on same object but keeps each reply separate" do
    user = fake_user!("notif_target")
    liker1 = fake_user!("liker1")
    liker2 = fake_user!("liker2")
    booster = fake_user!("booster")
    replier1 = fake_user!("feed_replier1")
    replier2 = fake_user!("feed_replier2")

    # User creates a post
    {:ok, %{id: post_id} = post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: "Notif test post"}},
        boundary: "public"
      )

    # Like from two different users
    {:ok, like1} = Bonfire.Social.Likes.like(liker1, post)
    {:ok, like2} = Bonfire.Social.Likes.like(liker2, post)

    # Boost from another user
    {:ok, boost} = Bonfire.Social.Boosts.boost(booster, post)

    # Two replies from different users
    {:ok, reply1} =
      Posts.publish(
        current_user: replier1,
        post_attrs: %{reply_to_id: post_id, post_content: %{html_body: "Reply 1"}},
        boundary: "public"
      )

    {:ok, reply2} =
      Posts.publish(
        current_user: replier2,
        post_attrs: %{reply_to_id: post_id, post_content: %{html_body: "Reply 2"}},
        boundary: "public"
      )

    # Fetch notifications feed for the target user
    {:ok, filters} = FeedLoader.preset_feed_filters(:notifications, current_user: user)
    %{edges: edges} = FeedLoader.feed(filters, [])

    # Find grouped like activities
    like_group =
      Enum.find(edges, fn edge ->
        edge.activity.verb_id == "11KES1ND1CATEAM11DAPPR0VA1" and
          (edge.activity.object_id == post_id or edge.activity.object.id == post_id)
      end)

    boost_group =
      Enum.find(edges, fn edge ->
        edge.activity.verb_id == "300ST0R0RANN0VCEANACT1V1TY" and
          (edge.activity.object_id == post_id or edge.activity.object.id == post_id)
      end)

    reply_edges =
      Enum.filter(edges, fn edge ->
        edge.activity.verb_id == Bonfire.Social.Activities.verb_id(:reply)
      end)

    # Check that likes are grouped and subjects contains both likers
    assert like_group
    assert Map.has_key?(like_group.activity, :subjects_more)

    subject_ids =
      Enum.map([like_group.activity.subject] ++ like_group.activity.subjects_more, &Enums.id/1)

    assert liker1.id in subject_ids
    assert liker2.id in subject_ids

    # Check that boost is grouped (should only be one booster)
    assert boost_group
    # assert Map.has_key?(boost_group.activity, :subjects_more)
    subject_ids =
      Enum.map([boost_group.activity.subject] ++ boost_group.activity.subjects_more, &Enums.id/1)

    assert [booster.id] == subject_ids

    # Should be two separate reply activities (not merged)
    assert length(reply_edges) == 2
    reply_subject_ids = Enum.map(reply_edges, &Enums.id(&1.activity.subject))
    assert replier1.id in reply_subject_ids
    assert replier2.id in reply_subject_ids
  end

  test "regular feed shows only 1 reply even when there are several replies to the same post (but merges likes/boosts by object and verb)" do
    user = fake_user!("feed_target")
    # liker1 = fake_user!("feed_liker1")
    # liker2 = fake_user!("feed_liker2")
    # booster = fake_user!("feed_booster")
    replier1 = fake_user!("feed_replier1")
    replier2 = fake_user!("feed_replier2")

    {:ok, %{id: post_id} = post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: "Feed test post"}},
        boundary: "public"
      )

    {:ok, _} =
      Posts.publish(
        current_user: replier1,
        post_attrs: %{reply_to_id: post_id, post_content: %{html_body: "Feed Reply 1"}},
        boundary: "public"
      )

    {:ok, _} =
      Posts.publish(
        current_user: replier2,
        post_attrs: %{reply_to_id: post_id, post_content: %{html_body: "Feed Reply 2"}},
        boundary: "public"
      )

    # Use :local feed for regular feed
    {:ok, filters} = FeedLoader.preset_feed_filters(:local, current_user: user)
    %{edges: edges} = FeedLoader.feed(filters, [])
    # debug(edges, "feed with replies")

    # Show only 1 reply (silently dropping the others, and just having the subjects available in `subjects_more`)
    reply_edges =
      Enum.filter(edges, fn edge ->
        edge.activity.verb_id == Bonfire.Social.Activities.verb_id(:reply)
      end)

    assert List.first(reply_edges).activity.replies_more_count == 1
    assert length(reply_edges) == 1

    # reply_subject_ids = Enum.flat_map(reply_edges, &([&1.activity.subject] ++ &1.activity.subjects_more)) |> Enums.ids()
    # assert replier1.id in reply_subject_ids
    # assert replier2.id in reply_subject_ids
  end
end
