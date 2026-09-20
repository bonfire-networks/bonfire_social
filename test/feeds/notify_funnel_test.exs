defmodule Bonfire.Social.Feeds.NotifyFunnelTest do
  @moduledoc """
  The write path every notification comes from, pinned before it is refactored.

  We're making `put_feed_publishes/2` the one place FeedPublish rows are built, so there can be one place where a notify job is enqueued, wraps the post-hoc publish route in a transaction, and dissolves `LivePush` into an `emit_live/1` called after commit. These tests describe what must stay true through all of that: which feeds get rows, what the live pipe broadcasts, and that retraction still reaches subscribers.
  """
  use Bonfire.Social.DataCase, async: false
  use Bonfire.Common.Utils

  alias Bonfire.Common.PubSub
  alias Bonfire.Common.Repo
  alias Bonfire.Data.Social.Activity
  alias Bonfire.Posts
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Feeds
  alias Bonfire.Social.Likes
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

  describe "the notify tap" do
    test "a mention through the Epic enqueues no fan_out, because an Act notifies instead" do
      alice = Fake.fake_user!()
      bob = Fake.fake_user!()

      {:ok, _post} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "hey @#{bob.character.username} look"}},
          boundary: "public"
        )

      # the posts epic tells this Act not to enqueue (`enqueue_notify: false`) because `Acts.LivePush` notifies after the commit, where a failure can be reported. Two notifications is what this catches
      Oban.Testing.refute_enqueued(Repo,
        worker: Bonfire.Notify.Worker,
        args: %{"op" => "fan_out"}
      )
    end

    test "an edge enqueues one fan_out, since no Act notifies for it" do
      alice = Fake.fake_user!()
      bob = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "alice posts for bob to like"}},
          boundary: "public"
        )

      assert {:ok, _like} = Likes.like(bob, post)

      alices_notifications = Feeds.my_feed_id(:notifications, alice)

      # the recipient the write path had already resolved, with the feed that reached them, so the job doesn't have to look them up
      Oban.Testing.assert_enqueued(Repo,
        worker: Bonfire.Notify.Worker,
        args: %{
          "op" => "fan_out",
          "recipients" => [%{"user_id" => alice.id, "feed" => "notifications"}],
          "feed_ids" => [alices_notifications]
        }
      )
    end

    test "a post that notifies nobody enqueues nothing" do
      alice = Fake.fake_user!()

      {:ok, _post} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "talking to myself"}},
          boundary: "public"
        )

      Oban.Testing.refute_enqueued(Repo, worker: Bonfire.Notify.Worker)
    end

    test "a publish whose transaction rolls back leaves no job" do
      alice = Fake.fake_user!()
      bob = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "alice posts, nobody notified"}},
          boundary: "public"
        )

      # an edge rather than a post, since the Epic runs acts in a Task that can't share this transaction's sandbox connection
      assert {:error, :changed_my_mind} =
               Repo.transact_with(fn ->
                 {:ok, _like} = Likes.like(bob, post)
                 {:error, :changed_my_mind}
               end)

      # the like notified alice, so a job was built inside that transaction and must have gone with it
      Oban.Testing.refute_enqueued(Repo, worker: Bonfire.Notify.Worker)
    end

    test "each kind of edge enqueues one fan_out, for its own recipient" do
      alice = Fake.fake_user!()
      bob = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "alice posts for others to react to"}},
          boundary: "public"
        )

      alices_notifications = Feeds.my_feed_id(:notifications, alice)

      for act <- [
            fn -> Likes.like(bob, post) end,
            fn -> Bonfire.Social.Boosts.boost(bob, post) end,
            fn -> Bonfire.Social.Graph.Follows.follow(bob, alice) end
          ] do
        assert {:ok, _} = act.()

        assert Oban.Testing.all_enqueued(Repo, worker: Bonfire.Notify.Worker)
               |> Enum.any?(&(alices_notifications in e(&1, :args, "feed_ids", [])))
      end
    end

    test "liking my own post notifies nobody" do
      alice = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "alice likes her own work"}},
          boundary: "public"
        )

      assert {:ok, _} = Likes.like(alice, post)

      Oban.Testing.refute_enqueued(Repo, worker: Bonfire.Notify.Worker)
    end

    test "the feed-addressing backfill never notifies" do
      alice = Fake.fake_user!()
      bob = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "an old post being backfilled"}},
          boundary: "public"
        )

      # the backfill writes FeedPublish rows straight to the table rather than through the funnel, which is what keeps it silent
      Bonfire.Social.Feeds.Addressing.Fill.migrate([
        %{id: post.id, feed_id: Feeds.my_feed_id(:notifications, bob)}
      ])

      Oban.Testing.refute_enqueued(Repo, worker: Bonfire.Notify.Worker)
    end

    test "every job knows which activity it is about" do
      alice = Fake.fake_user!()
      bob = Fake.fake_user!()

      {:ok, post} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "hey @#{bob.character.username}"}},
          boundary: "public"
        )

      {:ok, _like} = Likes.like(bob, post)
      {:ok, _boost} = Bonfire.Social.Boosts.boost(bob, post)

      jobs = Oban.Testing.all_enqueued(Repo, worker: Bonfire.Notify.Worker)

      assert length(jobs) == 2,
             "the two edges enqueue, while the post's own notification went to the Act instead"

      # an edge sets its id up front, and a job whose activity id was still nil is a notification nobody can say anything about
      for job <- jobs do
        activity_id = e(job, :args, "activity_id", nil)
        assert activity_id

        assert {:ok, _} =
                 Bonfire.Social.Activities.get(activity_id, skip_boundary_check: true),
               "the id a job carries must resolve to a real activity"
      end
    end

    test "a DM names its recipient's inbox, which is how it is told apart from a notification" do
      alice = Fake.fake_user!()
      bob = Fake.fake_user!()

      assert {:ok, _message} =
               Bonfire.Messages.send(
                 alice,
                 %{post_content: %{html_body: "just between us"}},
                 [bob]
               )

      # :inbox is only ever a DM, and DMs are delivered differently (their content stays private, so a push says who rather than what), which is why the feed that reached someone is carried rather than flattened into "notified"
      assert [job] = Oban.Testing.all_enqueued(Repo, worker: Bonfire.Notify.Worker)

      assert e(job, :args, "recipients", []) == [%{"user_id" => bob.id, "feed" => "inbox"}]
      assert e(job, :args, "feed_ids", []) == [Feeds.my_feed_id(:inbox, bob)]
    end

    test "a public post from someone I follow reaches no inbox, so it is never a DM" do
      alice = Fake.fake_user!()
      bob = Fake.fake_user!()

      assert {:ok, _} = Bonfire.Social.Graph.Follows.follow(bob, alice)

      {:ok, post} =
        Posts.publish(
          current_user: alice,
          post_attrs: %{post_content: %{html_body: "for my followers"}},
          boundary: "public"
        )

      bobs_inbox = Feeds.my_feed_id(:inbox, bob)
      published_to = FeedActivities.feeds_for_activity(post.id)

      assert published_to != [], "the post should have been published somewhere"

      refute bobs_inbox in published_to,
             "followed content reaches the home feed by querying outboxes, not by fanning out into inboxes"

      # inbox rows are DM-only by convention rather than by construction, so if that ever changes every followed post starts delivering as a private message
      for job <- Oban.Testing.all_enqueued(Repo, worker: Bonfire.Notify.Worker) do
        refute bobs_inbox in e(job, :args, "feed_ids", [])
        refute "inbox" in Enum.map(e(job, :args, "recipients", []), &e(&1, "feed", nil))
      end
    end

    test "with the notify extension disabled, publishing still works and enqueues nothing" do
      Process.put([:bonfire_notify, :modularity], :disabled)

      alice = Fake.fake_user!()
      bob = Fake.fake_user!()

      assert {:ok, _post} =
               Posts.publish(
                 current_user: alice,
                 post_attrs: %{post_content: %{html_body: "hey @#{bob.character.username}"}},
                 boundary: "public"
               )

      Oban.Testing.refute_enqueued(Repo, worker: Bonfire.Notify.Worker)
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
    test "a reply increments the answered author's unseen counter" do
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

    test "deleting an activity tells the feed to hide it" do
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
