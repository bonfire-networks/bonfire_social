defmodule Bonfire.Social.Feeds.NotifyFunnelTest do
  @moduledoc """
  The write path every notification comes from, pinned before it is refactored.

  We're making `put_feed_publishes/2` the one place FeedPublish rows are built, so there can be one place where a notify job is enqueued, wraps the post-hoc publish route in a transaction, and dissolves `LivePush` into an `emit_live/1` called after commit. These tests describe what must stay true through all of that: which feeds get rows, what the live pipe broadcasts, and that retraction still reaches subscribers.
  """
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Common.PubSub
  alias Bonfire.Data.Social.Activity
  alias Bonfire.Posts
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Feeds
  alias Bonfire.Me.Fake

  setup do
    Process.put([:bonfire_social, Bonfire.Social.Feeds, :feed_addressing], false)
    :ok
  end

  defp feed_ids_of(changeset) do
    changeset.changes.feed_publishes
    |> Enum.map(&Ecto.Changeset.get_field(&1, :feed_id))
    |> Enum.sort()
  end

  describe "the one row builder" do
    test "normalises what callers hand it" do
      user = Fake.fake_user!()
      feed_id = Feeds.my_feed_id(:notifications, user)

      # a feed can be named twice (as a recipient's notifications AND in an explicit list), nils arrive from unresolved characters, and a caller may pass the character or a named feed instead of an id, so normalising is the funnel's job rather than each caller's
      for feeds <- [[feed_id, feed_id], [feed_id, nil], [notifications: user]] do
        assert Ecto.Changeset.change(%Activity{})
               |> FeedActivities.put_feed_publishes(feeds)
               |> feed_ids_of() == [feed_id]
      end
    end
  end

  describe "the fan-out's own classification" do
    test "keeps which feeds are notifications, and which are not", %{} do
      alice = Fake.fake_user!()
      bob = Fake.fake_user!()

      %{all: all, notifications: notifications} =
        Feeds.fan_out_feeds(alice, "public", [bob], nil, nil)

      bobs_notifications = Feeds.my_feed_id(:notifications, bob)

      assert notifications == [bobs_notifications]

      # the public feeds and alice's own outbox are published to without notifying anyone
      assert bobs_notifications in all
      assert Feeds.my_feed_id(:outbox, alice) in all
      assert length(all) > length(notifications)

      # nobody notifies themselves, so a post with no mentions and no reply notifies no one
      assert %{notifications: []} = Feeds.fan_out_feeds(alice, "public", [], nil, nil)
    end
  end

  describe "the post-hoc publish route" do
    test "publishes to every feed or to none" do
      alice = Fake.fake_user!()
      bob = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "alice posts once"}},
          boundary: "public"
        )

      good_feed = Feeds.my_feed_id(:notifications, bob)

      # an id with nothing behind it, so the row's `:strong` pointer FK can't resolve: publishing has always raised on that, here it must also leave nothing behind
      bogus_feed = Needle.UID.generate()

      # a statement-level write has no changeset constraint for Ecto to translate, so the violation arrives raw
      assert_raise Postgrex.Error, fn ->
        FeedActivities.maybe_feed_publish(
          alice,
          e(post, :activity, nil),
          post,
          [good_feed, bogus_feed],
          []
        )
      end

      assert FeedLoader.feed(:notifications, %{}, current_user: bob, limit: 10)
             |> e(:edges, []) == [],
             "a fan-out that failed should leave no rows behind"
    end
  end

  describe "the live pipe" do
    test "a reply increments the answered author's unseen counter (T0.9)" do
      alice = Fake.fake_user!()
      bob = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "alice starts a thread"}},
          boundary: "public"
        )

      notifications_feed = Feeds.my_feed_id(:notifications, alice)
      :ok = PubSub.subscribe("unseen_count:#{notifications_feed}", current_user: alice)

      {:ok, _reply} =
        Posts.publish(
          current_user: bob,
          post_attrs: %{
            post_content: %{html_body: "bob answers alice"},
            reply_to_id: post.id
          },
          boundary: "public"
        )

      assert_receive {{Bonfire.Social.Feeds, :count_increment},
                      %{feed_id: ^notifications_feed, box: _box}},
                     5_000
    end

    test "deleting an activity tells the feed to hide it (T0.10)" do
      alice = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "alice posts then deletes"}},
          boundary: "public"
        )

      feed_id = Feeds.my_feed_id(:outbox, alice)
      :ok = PubSub.subscribe(feed_id, current_user: alice)

      FeedActivities.delete(post.id, :object_id)

      assert_receive {{Bonfire.Social.Feeds, :hide_activity}, [feed_ids: _, activity_id: _]},
                     5_000
    end
  end
end
