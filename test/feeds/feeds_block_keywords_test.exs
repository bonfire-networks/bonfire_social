defmodule Bonfire.Social.FeedsBlockKeywordsTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Threads
  alias Bonfire.Posts
  alias Bonfire.Common.Settings
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake

  describe "keyword-based feed filtering" do
    setup do
      user = fake_user!("keyword_filter_user")
      other_user = fake_user!("other_poster")

      # Create posts with various content
      normal_post =
        fake_post!(other_user, "public", %{
          post_content: %{
            name: "A normal post",
            html_body: "This is just a regular post about everyday things"
          }
        })

      spam_post =
        fake_post!(other_user, "public", %{
          post_content: %{
            name: "Buy cheap stuff",
            html_body: "Amazing deal on viagra and other products"
          }
        })

      keyword_in_name =
        fake_post!(other_user, "public", %{
          post_content: %{
            name: "Free crypto giveaway",
            html_body: "This is a legitimate post body"
          }
        })

      keyword_in_summary =
        fake_post!(other_user, "public", %{
          post_content: %{
            name: "Interesting article",
            summary: "Learn how to get free viagra today",
            html_body: "The actual content is fine"
          }
        })

      mixed_case_post =
        fake_post!(other_user, "public", %{
          post_content: %{
            name: "Mixed Case Test",
            html_body: "This post contains VIAGRA in uppercase"
          }
        })

      %{
        user: user,
        other_user: other_user,
        normal_post: normal_post,
        spam_post: spam_post,
        keyword_in_name: keyword_in_name,
        keyword_in_summary: keyword_in_summary,
        mixed_case_post: mixed_case_post
      }
    end

    test "filters posts containing blocked keywords in body", %{
      user: user,
      normal_post: normal_post,
      spam_post: spam_post
    } do
      # Set up keyword filter for user
      Process.put(
        [:bonfire_boundaries, :filter_keywords],
        ["viagra"]
      )

      feed =
        FeedLoader.feed(:explore, limit: 10, preload: [:with_post_content], current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )

      refute FeedLoader.feed_contains?(feed, spam_post,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )
    end

    test "filters posts containing blocked keywords in name", %{
      user: user,
      normal_post: normal_post,
      keyword_in_name: keyword_in_name
    } do
      Process.put(
        [:bonfire_boundaries, :filter_keywords],
        ["crypto"]
      )

      feed =
        FeedLoader.feed(:explore, limit: 10, preload: [:with_post_content], current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )

      refute FeedLoader.feed_contains?(feed, keyword_in_name,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )
    end

    test "filters posts containing blocked keywords in summary", %{
      user: user,
      normal_post: normal_post,
      keyword_in_summary: keyword_in_summary
    } do
      Process.put(
        [:bonfire_boundaries, :filter_keywords],
        ["viagra"]
      )

      feed =
        FeedLoader.feed(:explore, limit: 10, preload: [:with_post_content], current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )

      refute FeedLoader.feed_contains?(feed, keyword_in_summary,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )
    end

    test "keyword matching is case-insensitive", %{
      user: user,
      normal_post: normal_post,
      mixed_case_post: mixed_case_post
    } do
      # Keywords are stored lowercase, matching should be case-insensitive
      Process.put(
        [:bonfire_boundaries, :filter_keywords],
        ["viagra"]
      )

      feed =
        FeedLoader.feed(:explore, limit: 10, preload: [:with_post_content], current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )

      refute FeedLoader.feed_contains?(feed, mixed_case_post,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )
    end

    test "filters with multiple keywords", %{
      user: user,
      normal_post: normal_post,
      spam_post: spam_post,
      keyword_in_name: keyword_in_name
    } do
      Process.put(
        [:bonfire_boundaries, :filter_keywords],
        ["viagra", "crypto"]
      )

      feed =
        FeedLoader.feed(:explore, limit: 10, preload: [:with_post_content], current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )

      refute FeedLoader.feed_contains?(feed, spam_post,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )

      refute FeedLoader.feed_contains?(feed, keyword_in_name,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )
    end

    test "shows all posts when no keywords configured", %{
      user: user,
      normal_post: normal_post,
      spam_post: spam_post
    } do
      # No filter_keywords setting
      feed =
        FeedLoader.feed(:explore, limit: 10, preload: [:with_post_content], current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )

      assert FeedLoader.feed_contains?(feed, spam_post,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )
    end

    test "shows all posts when keywords list is empty", %{
      user: user,
      normal_post: normal_post,
      spam_post: spam_post
    } do
      Process.put(
        [:bonfire_boundaries, :filter_keywords],
        []
      )

      feed =
        FeedLoader.feed(:explore, limit: 10, preload: [:with_post_content], current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )

      assert FeedLoader.feed_contains?(feed, spam_post,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )
    end

    test "different users have independent keyword filters (using Settings saved in DB)", %{
      user: user,
      other_user: other_user,
      spam_post: spam_post
    } do
      # User has filter, other_user doesn't
      user =
        Settings.set(
          %{bonfire_boundaries: %{filter_keywords: ["Viagra"]}},
          current_user: user
        )
        |> current_user()

      user_feed =
        FeedLoader.feed(:explore, limit: 10, preload: [:with_post_content], current_user: user)

      refute FeedLoader.feed_contains?(user_feed, spam_post,
               limit: 10,
               preload: [:with_post_content],
               current_user: user
             )

      viewer_feed =
        FeedLoader.feed(:explore,
          limit: 10,
          preload: [:with_post_content],
          current_user: other_user
        )

      assert FeedLoader.feed_contains?(viewer_feed, spam_post,
               limit: 10,
               preload: [:with_post_content],
               current_user: other_user
             )
    end
  end

  describe "keyword-based thread filtering" do
    setup do
      user = fake_user!("thread_viewer")
      poster = fake_user!("thread_poster")

      # Create a thread with normal content
      {:ok, normal_thread} =
        Posts.publish(
          current_user: poster,
          post_attrs: %{
            post_content: %{
              name: "Normal discussion",
              html_body: "Let's talk about everyday topics"
            }
          },
          boundary: "public"
        )

      # Normal reply to the thread
      {:ok, normal_reply} =
        Posts.publish(
          current_user: poster,
          post_attrs: %{
            post_content: %{
              html_body: "This is a thoughtful reply"
            },
            reply_to_id: normal_thread.id
          },
          boundary: "public"
        )

      # Spam reply to the thread
      {:ok, spam_reply} =
        Posts.publish(
          current_user: poster,
          post_attrs: %{
            post_content: %{
              html_body: "Buy cheap viagra now!"
            },
            reply_to_id: normal_thread.id
          },
          boundary: "public"
        )

      # Another normal reply
      {:ok, another_normal_reply} =
        Posts.publish(
          current_user: poster,
          post_attrs: %{
            post_content: %{
              html_body: "Another good contribution to the discussion"
            },
            reply_to_id: normal_thread.id
          },
          boundary: "public"
        )

      %{
        user: user,
        poster: poster,
        normal_thread: normal_thread,
        normal_reply: normal_reply,
        spam_reply: spam_reply,
        another_normal_reply: another_normal_reply
      }
    end

    test "filters replies containing blocked keywords from thread", %{
      user: user,
      normal_thread: normal_thread,
      normal_reply: normal_reply,
      spam_reply: spam_reply,
      another_normal_reply: another_normal_reply
    } do
      Process.put([:bonfire_boundaries, :filter_keywords], ["viagra"])

      %{edges: replies} = Threads.list_replies(normal_thread.id, current_user: user)

      reply_ids = Enum.map(replies, & &1.id)

      assert normal_reply.id in reply_ids
      assert another_normal_reply.id in reply_ids
      refute spam_reply.id in reply_ids
    end

    test "shows all replies when no keywords configured", %{
      user: user,
      normal_thread: normal_thread,
      normal_reply: normal_reply,
      spam_reply: spam_reply,
      another_normal_reply: another_normal_reply
    } do
      # No filter configured
      %{edges: replies} = Threads.list_replies(normal_thread.id, current_user: user)

      reply_ids = Enum.map(replies, & &1.id)

      assert normal_reply.id in reply_ids
      assert spam_reply.id in reply_ids
      assert another_normal_reply.id in reply_ids
    end

    test "filters nested replies containing blocked keywords", %{
      user: user,
      poster: poster,
      normal_thread: normal_thread,
      normal_reply: normal_reply
    } do
      # Create a nested reply with spam content
      {:ok, nested_spam} =
        Posts.publish(
          current_user: poster,
          post_attrs: %{
            post_content: %{
              html_body: "Get free crypto giveaway here!"
            },
            reply_to_id: normal_reply.id
          },
          boundary: "public"
        )

      # Create a normal nested reply
      {:ok, nested_normal} =
        Posts.publish(
          current_user: poster,
          post_attrs: %{
            post_content: %{
              html_body: "I agree with your point"
            },
            reply_to_id: normal_reply.id
          },
          boundary: "public"
        )

      Process.put([:bonfire_boundaries, :filter_keywords], ["crypto"])

      %{edges: replies} = Threads.list_replies(normal_thread.id, current_user: user)

      reply_ids = Enum.map(replies, & &1.id)

      assert normal_reply.id in reply_ids
      assert nested_normal.id in reply_ids
      refute nested_spam.id in reply_ids
    end

    test "different users see different filtered threads based on their settings", %{
      poster: poster,
      normal_thread: normal_thread,
      spam_reply: spam_reply
    } do
      # Create two viewers with different filter settings
      viewer_with_filter = fake_user!("filtered_viewer")
      viewer_without_filter = fake_user!("unfiltered_viewer")

      # Set filter for one user via Settings DB
      viewer_with_filter =
        Settings.set(
          %{bonfire_boundaries: %{filter_keywords: ["viagra"]}},
          current_user: viewer_with_filter
        )
        |> current_user()

      # User with filter should not see spam reply
      %{edges: filtered_replies} =
        Threads.list_replies(normal_thread.id, current_user: viewer_with_filter)

      filtered_ids = Enum.map(filtered_replies, & &1.id)
      refute spam_reply.id in filtered_ids

      # User without filter should see all replies
      %{edges: unfiltered_replies} =
        Threads.list_replies(normal_thread.id, current_user: viewer_without_filter)

      unfiltered_ids = Enum.map(unfiltered_replies, & &1.id)
      assert spam_reply.id in unfiltered_ids
    end
  end

  describe "keyword filtering for PubSub activities" do
    alias Bonfire.Common.PubSub
    alias Bonfire.Social.Feeds

    test "show_activity?/2 returns false for activities matching blocked keywords" do
      user = fake_user!("pubsub_filter_user")

      # Set up keyword filter
      Process.put([:bonfire_boundaries, :filter_keywords], ["viagra"])

      # Create an activity with blocked content
      spam_activity = %{
        id: "test_activity",
        object_post_content: %{
          html_body: "Buy cheap viagra now!"
        }
      }

      # The activity should be filtered
      refute Bonfire.Social.show_activity?(spam_activity, current_user: user)
    end

    test "show_activity?/2 returns true for normal activities" do
      user = fake_user!("pubsub_normal_user")

      # Set up keyword filter
      Process.put([:bonfire_boundaries, :filter_keywords], ["viagra"])

      # Create a normal activity
      normal_activity = %{
        id: "test_activity",
        object_post_content: %{
          html_body: "This is a normal post about cats"
        }
      }

      # The activity should not be filtered
      assert Bonfire.Social.show_activity?(normal_activity, current_user: user)
    end

    test "show_activity?/2 returns true when no keywords configured" do
      user = fake_user!("pubsub_no_filter_user")

      # No filter configured

      # Even spam content should pass through
      spam_activity = %{
        id: "test_activity",
        object_post_content: %{
          html_body: "Buy cheap viagra now!"
        }
      }

      assert Bonfire.Social.show_activity?(spam_activity, current_user: user)
    end

    test "PubSub receives activity but it should be filtered by keyword" do
      viewer = fake_user!("pubsub_keyword_viewer")
      poster = fake_user!("pubsub_keyword_poster")

      # Set up keyword filter for viewer
      viewer =
        Settings.set(
          %{bonfire_boundaries: %{filter_keywords: ["viagra"]}},
          current_user: viewer
        )
        |> current_user()

      # Subscribe to local feed
      feed_id = Feeds.named_feed_id(:local)
      :ok = PubSub.subscribe(feed_id, current_user: viewer)

      # Post spam content
      {:ok, spam_post} =
        Posts.publish(
          current_user: poster,
          post_attrs: %{post_content: %{html_body: "Amazing viagra deals today!"}},
          boundary: "public"
        )

      # The PubSub message is received (broadcast happens regardless)
      assert_receive {
        {Bonfire.Social.Feeds, :new_activity},
        [feed_ids: _, activity: received_activity]
      }

      # But when checking if it should be shown, it should be filtered
      refute Bonfire.Social.show_activity?(received_activity, current_user: viewer)
    end

    test "PubSub thread reply should be filtered by keyword" do
      viewer = fake_user!("pubsub_thread_viewer")
      poster = fake_user!("pubsub_thread_poster")

      # Set up keyword filter for viewer
      viewer =
        Settings.set(
          %{bonfire_boundaries: %{filter_keywords: ["crypto"]}},
          current_user: viewer
        )
        |> current_user()

      # Create a thread
      {:ok, thread} =
        Posts.publish(
          current_user: poster,
          post_attrs: %{post_content: %{html_body: "Normal thread root"}},
          boundary: "public"
        )

      # Subscribe to the thread
      :ok = PubSub.subscribe(thread.id, current_user: viewer)

      # Post a spam reply
      {:ok, spam_reply} =
        Posts.publish(
          current_user: poster,
          post_attrs: %{
            post_content: %{html_body: "Get free crypto giveaway!"},
            reply_to: thread.id
          },
          boundary: "public"
        )

      # The PubSub message is received
      assert_receive {
        {Bonfire.Social.Threads.LiveHandler, :new_reply},
        {_thread_id, received_activity}
      }

      # But when checking if it should be shown, it should be filtered
      refute Bonfire.Social.show_activity?(received_activity, current_user: viewer)
    end
  end
end
