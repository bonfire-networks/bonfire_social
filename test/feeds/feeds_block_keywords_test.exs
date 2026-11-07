defmodule Bonfire.Social.FeedsBlockKeywordsTest do
  use Bonfire.Social.DataCase, async: false
  use Bonfire.Common.Utils

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Threads
  alias Bonfire.Posts
  alias Bonfire.Common.Settings
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake

  defp reply_body_visible?(replies, reply_id, expected_body) do
    Enum.find_value(replies, false, fn edge ->
      if edge.id == reply_id do
        body =
          e(edge, :activity, :object, :post_content, :html_body, nil) ||
            e(edge, :activity, :object, :post_content, :summary, nil)

        body && body =~ expected_body
      end
    end)
  end

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
      normal_post: normal_post
    } do
      Process.put([:activity_pub, :mrf_keyword, :reject], ["viagra"])

      feed = FeedLoader.feed_postloaded(:explore, limit: 10, current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post, postload: false)

      refute FeedLoader.feed_contains?(feed, "Amazing deal on viagra and other products",
               postload: false
             )
    end

    test "filters posts containing blocked keywords in name", %{
      user: user,
      normal_post: normal_post
    } do
      Process.put([:activity_pub, :mrf_keyword, :reject], ["crypto"])

      feed = FeedLoader.feed_postloaded(:explore, limit: 10, current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post, postload: false)

      refute FeedLoader.feed_contains?(feed, "Free crypto giveaway", postload: false)
    end

    test "filters posts containing blocked keywords in summary", %{
      user: user,
      normal_post: normal_post
    } do
      Process.put([:activity_pub, :mrf_keyword, :reject], ["viagra"])

      feed = FeedLoader.feed_postloaded(:explore, limit: 10, current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post, postload: false)

      refute FeedLoader.feed_contains?(feed, "Learn how to get free viagra today",
               postload: false
             )
    end

    test "keyword matching is case-insensitive", %{
      user: user,
      normal_post: normal_post
    } do
      Process.put([:activity_pub, :mrf_keyword, :reject], ["viagra"])

      feed = FeedLoader.feed_postloaded(:explore, limit: 10, current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post, postload: false)

      refute FeedLoader.feed_contains?(feed, "This post contains VIAGRA in uppercase",
               postload: false
             )
    end

    test "filters with multiple keywords", %{
      user: user,
      normal_post: normal_post
    } do
      Process.put([:activity_pub, :mrf_keyword, :reject], ["viagra", "crypto"])

      feed = FeedLoader.feed_postloaded(:explore, limit: 10, current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post, postload: false)

      refute FeedLoader.feed_contains?(feed, "Amazing deal on viagra and other products",
               postload: false
             )

      refute FeedLoader.feed_contains?(feed, "Free crypto giveaway", postload: false)
    end

    test "shows all posts when no keywords configured", %{
      user: user,
      normal_post: normal_post,
      spam_post: spam_post
    } do
      feed = FeedLoader.feed_postloaded(:explore, limit: 10, current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post, postload: false)
      assert FeedLoader.feed_contains?(feed, spam_post, postload: false)
    end

    test "shows all posts when keywords list is empty", %{
      user: user,
      normal_post: normal_post,
      spam_post: spam_post
    } do
      Process.put([:activity_pub, :mrf_keyword, :reject], [])

      feed = FeedLoader.feed_postloaded(:explore, limit: 10, current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post, postload: false)
      assert FeedLoader.feed_contains?(feed, spam_post, postload: false)
    end

    test "different users have independent keyword filters (using Settings saved in DB)", %{
      user: user,
      other_user: other_user,
      spam_post: spam_post
    } do
      user =
        Settings.set(
          %{activity_pub: %{mrf_keyword: %{reject: ["Viagra"]}}},
          current_user: user
        )
        |> current_user()

      user_feed = FeedLoader.feed_postloaded(:explore, limit: 10, current_user: user)

      refute FeedLoader.feed_contains?(user_feed, "Amazing deal on viagra and other products",
               postload: false
             )

      viewer_feed = FeedLoader.feed_postloaded(:explore, limit: 10, current_user: other_user)

      assert FeedLoader.feed_contains?(viewer_feed, spam_post, postload: false)
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

    test "hides content of replies containing blocked keywords from thread", %{
      user: user,
      normal_thread: normal_thread,
      normal_reply: normal_reply,
      spam_reply: spam_reply,
      another_normal_reply: another_normal_reply
    } do
      Process.put([:activity_pub, :mrf_keyword, :reject], ["viagra"])

      %{edges: replies} =
        Threads.list_replies(normal_thread.id, current_user: user, postload: [:with_post_content])

      # All replies are still in the list
      reply_ids = Enum.map(replies, & &1.id)
      assert normal_reply.id in reply_ids
      assert spam_reply.id in reply_ids
      assert another_normal_reply.id in reply_ids

      # But the spam reply content is replaced
      refute reply_body_visible?(replies, spam_reply.id, "Buy cheap viagra now!")
      assert reply_body_visible?(replies, normal_reply.id, "This is a thoughtful reply")
    end

    test "shows all replies when no keywords configured", %{
      user: user,
      normal_thread: normal_thread,
      normal_reply: normal_reply,
      spam_reply: spam_reply,
      another_normal_reply: another_normal_reply
    } do
      %{edges: replies} =
        Threads.list_replies(normal_thread.id, current_user: user, postload: [:with_post_content])

      reply_ids = Enum.map(replies, & &1.id)
      assert normal_reply.id in reply_ids
      assert spam_reply.id in reply_ids
      assert another_normal_reply.id in reply_ids

      assert reply_body_visible?(replies, spam_reply.id, "Buy cheap viagra now!")
    end

    test "hides content of nested replies containing blocked keywords", %{
      user: user,
      poster: poster,
      normal_thread: normal_thread,
      normal_reply: normal_reply
    } do
      {:ok, nested_spam} =
        Posts.publish(
          current_user: poster,
          post_attrs: %{
            post_content: %{html_body: "Get free crypto giveaway here!"},
            reply_to_id: normal_reply.id
          },
          boundary: "public"
        )

      {:ok, nested_normal} =
        Posts.publish(
          current_user: poster,
          post_attrs: %{
            post_content: %{html_body: "I agree with your point"},
            reply_to_id: normal_reply.id
          },
          boundary: "public"
        )

      Process.put([:activity_pub, :mrf_keyword, :reject], ["crypto"])

      %{edges: replies} =
        Threads.list_replies(normal_thread.id, current_user: user, postload: [:with_post_content])

      reply_ids = Enum.map(replies, & &1.id)
      assert normal_reply.id in reply_ids
      assert nested_normal.id in reply_ids
      assert nested_spam.id in reply_ids

      refute reply_body_visible?(replies, nested_spam.id, "Get free crypto giveaway here!")
      assert reply_body_visible?(replies, nested_normal.id, "I agree with your point")
    end

    test "different users see different filtered thread content based on their settings", %{
      normal_thread: normal_thread,
      spam_reply: spam_reply
    } do
      viewer_with_filter = fake_user!("filtered_viewer")
      viewer_without_filter = fake_user!("unfiltered_viewer")

      viewer_with_filter =
        Settings.set(
          %{activity_pub: %{mrf_keyword: %{reject: ["viagra"]}}},
          current_user: viewer_with_filter
        )
        |> current_user()

      %{edges: filtered_replies} =
        Threads.list_replies(normal_thread.id,
          current_user: viewer_with_filter,
          postload: [:with_post_content]
        )

      # Reply still present but content hidden
      assert spam_reply.id in Enum.map(filtered_replies, & &1.id)
      refute reply_body_visible?(filtered_replies, spam_reply.id, "Buy cheap viagra now!")

      %{edges: unfiltered_replies} =
        Threads.list_replies(normal_thread.id,
          current_user: viewer_without_filter,
          postload: [:with_post_content]
        )

      assert reply_body_visible?(unfiltered_replies, spam_reply.id, "Buy cheap viagra now!")
    end
  end

  # The tests above use `Process.put`, which short-circuits `Settings.get` before the DB path, so the settings load hook never runs. These store the keywords in the user's settings row like production does.
  describe "keywords stored in the user's DB settings" do
    setup do
      user = fake_user!("db_keyword_user")
      keywords = ["viagra" | for(i <- 1..199, do: "blockedword#{i}")]

      {:ok, _} =
        Bonfire.Boundaries.BlockKeywords.put_block_keywords_settings(keywords, current_user: user)

      user = Bonfire.Common.Repo.preload(user, :settings, force: true)

      %{user: user}
    end

    test "stored keywords reach the filter as a compiled pattern", %{user: user} do
      assert %{regex: %Regex{}} =
               Bonfire.Boundaries.BlockKeywords.block_keywords_settings(current_user: user)
    end

    test "saving another setting keeps the stored keywords and persists no compiled pattern", %{
      user: user
    } do
      # an unrelated, harmless user setting whose atoms already exist (`put` drops unknown atoms)
      assert {:ok, %{__context__: %{current_user: user}}} =
               Bonfire.Common.Settings.put(
                 [:bonfire_social, Bonfire.Social.Feeds, :feed_presets, :test],
                 %{name: :test, filters: %{}},
                 current_user: user
               )

      user = Bonfire.Common.Repo.preload(user, :settings, force: true)

      assert length(get_in(user.settings.json, [:activity_pub, :mrf_keyword, :reject])) == 200
      refute get_in(user.settings.json, [:activity_pub, :mrf_keyword, :reject_compiled])
      assert Bonfire.Boundaries.BlockKeywords.block_keywords_settings(current_user: user)
    end

    test "the compiled pattern is built once, not on every Settings.get", %{user: user} do
      a = Bonfire.Boundaries.BlockKeywords.block_keywords_settings(current_user: user)
      b = Bonfire.Boundaries.BlockKeywords.block_keywords_settings(current_user: user)

      assert %{regex: %Regex{}} = a
      assert a === b
    end

    test "a feed still filters posts matching one of 200 stored keywords", %{user: user} do
      other_user = fake_user!("db_keyword_poster")

      normal_post =
        fake_post!(other_user, "public", %{
          post_content: %{name: "A normal post", html_body: "Just a regular post"}
        })

      _spam_post =
        fake_post!(other_user, "public", %{
          post_content: %{name: "Buy cheap stuff", html_body: "Amazing deal on viagra"}
        })

      feed = FeedLoader.feed_postloaded(:explore, limit: 10, current_user: user)

      assert FeedLoader.feed_contains?(feed, normal_post, postload: false)
      refute FeedLoader.feed_contains?(feed, "Amazing deal on viagra", postload: false)
    end
  end

  # A keyword matches a whole word of what a reader sees; a `*` at either end lets it run into a longer word. Keywords are stored in the viewer's settings row, as the settings page does.
  describe "keywords match whole words of the visible text" do
    setup do
      viewer = fake_user!("kw_words_viewer")
      author = fake_user!("kw_words_author")
      %{viewer: viewer, author: author}
    end

    defp with_keywords(user, keywords) do
      {:ok, _} =
        Bonfire.Boundaries.BlockKeywords.put_block_keywords_settings(keywords, current_user: user)

      Bonfire.Common.Repo.preload(user, :settings, force: true)
    end

    defp post!(author, html_body),
      do: fake_post!(author, "public", %{post_content: %{html_body: html_body}})

    # the text as the viewer's feed shows it
    defp shown?(viewer, text) do
      :explore
      |> FeedLoader.feed_postloaded(limit: 20, current_user: viewer)
      |> FeedLoader.feed_contains?(text, postload: false)
    end

    test "a keyword hides a post with the whole word, not one with a longer word", %{
      viewer: viewer,
      author: author
    } do
      post!(author, "Spam! again")
      post!(author, "the spammer is back")
      viewer = with_keywords(viewer, ["spam"])

      refute shown?(viewer, "Spam! again")
      assert shown?(viewer, "the spammer is back")
    end

    test "a * at the end also hides longer words starting with the keyword", %{
      viewer: viewer,
      author: author
    } do
      post!(author, "the spammer is back")
      viewer = with_keywords(viewer, ["spam*"])

      refute shown?(viewer, "the spammer is back")
    end

    test "a short keyword does not hide posts where it is only inside other words", %{
      viewer: viewer,
      author: author
    } do
      post!(author, "a class on passing")
      post!(author, ~s(<p>see <a href="https://x.local">this link</a></p>))
      viewer = with_keywords(viewer, ["ass", "href"])

      assert shown?(viewer, "a class on passing")
      assert shown?(viewer, "this link")
    end

    test "a keyword that is a hashtag hides a post with that hashtag", %{
      viewer: viewer,
      author: author
    } do
      post!(author, "I love #cats today")
      post!(author, "I love cats today")
      viewer = with_keywords(viewer, ["#cats"])

      refute shown?(viewer, "#cats today")
      assert shown?(viewer, "I love cats today")
    end

    test "the instance's list does not hide posts from a user's feed", %{
      viewer: viewer,
      author: author
    } do
      # an instance save also puts the list (and what the load hook makes of it) into the app config, which every later test reads: put back exactly what was there (the stored row goes with the test's transaction)
      previous_config = Application.get_env(:activity_pub, :mrf_keyword)

      on_exit(fn ->
        if previous_config,
          do: Application.put_env(:activity_pub, :mrf_keyword, previous_config),
          else: Application.delete_env(:activity_pub, :mrf_keyword)
      end)

      # published before the instance's list has the word: a local post published after it would be kept to its author, which is not what this is about
      post!(author, "a post saying instancebanned")

      {:ok, _} =
        Bonfire.Common.Settings.put_raw(
          [:activity_pub, :mrf_keyword, :reject],
          ["instancebanned"],
          scope: :instance,
          skip_boundary_check: true
        )

      viewer = Bonfire.Common.Repo.preload(viewer, :settings, force: true)

      assert shown?(viewer, "a post saying instancebanned")
    end
  end
end
