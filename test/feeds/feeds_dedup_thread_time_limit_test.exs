defmodule Bonfire.Social.FeedsDedupThreadTimeLimitTest do
  @moduledoc """
  Regression tests for `dedup_by_thread` feeds (used by the group "Discussions" tab via the `:recent_discussions` preset):

  1. the time window must apply to a thread's LATEST activity (matching the latest-reply sort), not to the thread root's own timestamp — an old thread with fresh replies must stay visible

  2. a thread whose root was never published to the queried feed (e.g. it predates the group) must still appear, represented by its earliest entry in that feed — and its window/ranking must still follow the thread's latest reply, not that earliest entry's own age

  3. an entry that is itself recent (e.g. a fresh boost of an old post) counts as thread activity for the window
  """
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Feeds

  defp fake_post_days_ago!(user, days, attrs) do
    fake_post!(
      user,
      "public",
      Map.put(attrs, :id, DatesTimes.past(days, :day) |> DatesTimes.generate_ulid())
    )
  end

  describe "dedup_by_thread applies the time window to the thread's latest activity" do
    setup do
      %{user: fake_user!("thread window viewer"), author: fake_user!("thread window author")}
    end

    test "keeps a thread started before the window when its latest reply is within it", %{
      user: user,
      author: author
    } do
      old_root =
        fake_post_days_ago!(author, 10, %{
          post_content: %{name: "old active thread", html_body: "root from ten days ago"}
        })

      _fresh_reply =
        fake_post!(author, "public", %{
          post_content: %{html_body: "fresh reply to the old thread"},
          reply_to_id: old_root.id
        })

      feed =
        FeedLoader.feed(:local, %{dedup_by_thread: true, time_limit: 7}, current_user: user)

      assert FeedLoader.feed_contains?(feed, old_root, current_user: user)
    end

    test "hides a thread whose latest activity is older than the window", %{
      user: user,
      author: author
    } do
      old_root =
        fake_post_days_ago!(author, 10, %{
          post_content: %{name: "old stale thread", html_body: "root from ten days ago"}
        })

      _old_reply =
        fake_post_days_ago!(author, 9, %{
          post_content: %{html_body: "reply from nine days ago"},
          reply_to_id: old_root.id
        })

      feed =
        FeedLoader.feed(:local, %{dedup_by_thread: true, time_limit: 7}, current_user: user)

      refute FeedLoader.feed_contains?(feed, old_root, current_user: user)
    end

    test "keeps a fresh thread with no replies", %{user: user, author: author} do
      fresh_root =
        fake_post!(author, "public", %{
          post_content: %{name: "fresh thread", html_body: "root from just now"}
        })

      feed =
        FeedLoader.feed(:local, %{dedup_by_thread: true, time_limit: 7}, current_user: user)

      assert FeedLoader.feed_contains?(feed, fresh_root, current_user: user)
    end

    test "ranks an old thread with the most recent reply above fresher-started threads", %{
      user: user,
      author: author
    } do
      fresh_root =
        fake_post!(author, "public", %{
          post_content: %{name: "fresh but quiet thread", html_body: "recent root, no replies"}
        })

      old_root =
        fake_post_days_ago!(author, 10, %{
          post_content: %{name: "old busy thread", html_body: "root from ten days ago"}
        })

      # created after fresh_root, so this thread has the most recent activity overall
      _fresh_reply =
        fake_post!(author, "public", %{
          post_content: %{html_body: "newest reply overall"},
          reply_to_id: old_root.id
        })

      %{edges: edges} =
        FeedLoader.feed(:local, %{dedup_by_thread: true, time_limit: 7}, current_user: user)

      ids = Enum.map(edges, &e(&1, :activity, :object_id, nil))

      old_pos = Enum.find_index(ids, &(&1 == old_root.id))
      fresh_pos = Enum.find_index(ids, &(&1 == fresh_root.id))

      assert old_pos != nil, "old thread with fresh reply should be in the feed"
      assert fresh_pos != nil, "fresh thread should be in the feed"

      assert old_pos < fresh_pos,
             "the old thread (latest activity) should rank above the fresher-started thread"
    end
  end

  describe "dedup_by_thread when the thread root is not in the queried feed" do
    setup do
      %{
        user: fake_user!("rootless viewer"),
        author: fake_user!("rootless author"),
        replier: fake_user!("rootless replier")
      }
    end

    test "represents the thread by its earliest entry instead of hiding it", %{
      user: user,
      author: author,
      replier: replier
    } do
      root =
        fake_post!(author, "public", %{
          post_content: %{name: "thread rooted elsewhere", html_body: "root not in this feed"}
        })

      reply1 =
        fake_post!(replier, "public", %{
          post_content: %{html_body: "first reply in this feed"},
          reply_to_id: root.id
        })

      reply2 =
        fake_post!(replier, "public", %{
          post_content: %{html_body: "second reply in this feed"},
          reply_to_id: root.id
        })

      # the replier's outbox contains their replies but never the root's own activity
      # (using the :recent_discussions preset + feed_ids, same as the group Discussions tab)
      feed =
        FeedLoader.feed(
          :recent_discussions,
          %{feed_ids: [Feeds.feed_id(:outbox, replier)]},
          current_user: user
        )

      assert FeedLoader.feed_contains?(feed, reply1, current_user: user),
             "the thread should appear via its earliest entry in the feed"

      refute FeedLoader.feed_contains?(feed, reply2, current_user: user),
             "the thread should only appear once"

      refute FeedLoader.feed_contains?(feed, root, current_user: user)
    end

    test "windows a rootless thread by its latest reply, not by its earliest entry's age", %{
      user: user,
      author: author,
      replier: replier
    } do
      root =
        fake_post_days_ago!(author, 15, %{
          post_content: %{name: "old thread rooted elsewhere", html_body: "old root not in this feed"}
        })

      old_reply =
        fake_post_days_ago!(replier, 10, %{
          post_content: %{html_body: "old first reply in this feed"},
          reply_to_id: root.id
        })

      _fresh_reply =
        fake_post!(replier, "public", %{
          post_content: %{html_body: "fresh reply in this feed"},
          reply_to_id: root.id
        })

      feed =
        FeedLoader.feed(
          :recent_discussions,
          %{feed_ids: [Feeds.feed_id(:outbox, replier)], time_limit: 7},
          current_user: user
        )

      # the representative entry (the old first reply) predates the window, but the thread's latest reply is fresh
      assert FeedLoader.feed_contains?(feed, old_reply, current_user: user),
             "an active rootless thread should stay visible even when its earliest in-feed entry is older than the window"
    end

    test "still prefers the root's own entry when it is in the feed", %{
      user: user,
      author: author
    } do
      root =
        fake_post!(author, "public", %{
          post_content: %{name: "self-replied thread", html_body: "root in this feed"}
        })

      reply =
        fake_post!(author, "public", %{
          post_content: %{html_body: "author's own reply"},
          reply_to_id: root.id
        })

      # the author's outbox contains both the root and the reply
      feed =
        FeedLoader.feed(
          :recent_discussions,
          %{feed_ids: [Feeds.feed_id(:outbox, author)]},
          current_user: user
        )

      assert FeedLoader.feed_contains?(feed, root, current_user: user)

      refute FeedLoader.feed_contains?(feed, reply, current_user: user),
             "the thread should be represented by its root, not also by the reply"
    end
  end

  describe "dedup_by_thread counts a recent entry itself as thread activity" do
    test "shows a fresh boost of an old unreplied post within the window" do
      user = fake_user!("boost window viewer")
      author = fake_user!("boost window author")
      booster = fake_user!("boost window booster")

      old_post =
        fake_post_days_ago!(author, 10, %{
          post_content: %{name: "old unreplied post", html_body: "posted ten days ago"}
        })

      {:ok, _boost} = Bonfire.Social.Boosts.boost(booster, old_post)

      feed =
        FeedLoader.feed(
          :recent_discussions,
          %{feed_ids: [Feeds.feed_id(:outbox, booster)], time_limit: 7},
          current_user: user
        )

      assert FeedLoader.feed_contains?(feed, old_post, current_user: user),
             "a fresh boost should count as recent thread activity even though the boosted post is older than the window"
    end
  end
end
