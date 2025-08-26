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

    Config.put(:default_pagination_limit, 20)

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
      Enum.map(
        [boost_group.activity.subject] ++ e(boost_group.activity, :subjects_more, []),
        &Enums.id/1
      )

    assert [booster.id] == subject_ids

    # Should be two separate reply activities (not merged)
    assert length(reply_edges) == 2
    reply_subject_ids = Enum.map(reply_edges, &Enums.id(&1.activity.subject))
    assert replier1.id in reply_subject_ids
    assert replier2.id in reply_subject_ids
  end

  test "regular feed shows only 1 reply even when there are several replies to the same post (but merges likes/boosts by object and verb)" do
    user = fake_user!("feed_target")
    liker1 = fake_user!("feed_liker1")
    liker2 = fake_user!("feed_liker2")
    booster = fake_user!("feed_booster")
    replier1 = fake_user!("feed_replier1")
    replier2 = fake_user!("feed_replier2")
    replier3 = fake_user!("feed_replier3")
    other_user = fake_user!("other_user")

    {:ok, %{id: post_id} = post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: "Feed test post"}},
        boundary: "public"
      )

    {:ok, %{id: reply1_id} = reply1} =
      Posts.publish(
        current_user: replier1,
        post_attrs: %{reply_to_id: post_id, post_content: %{html_body: "Feed Reply 1"}},
        boundary: "public"
      )

    {:ok, %{id: reply2_id} = reply2} =
      Posts.publish(
        current_user: replier2,
        post_attrs: %{reply_to_id: post_id, post_content: %{html_body: "Feed Reply 2"}},
        boundary: "public"
      )

    # Add a nested reply (reply to a reply)
    {:ok, %{id: nested_reply_id} = nested_reply} =
      Posts.publish(
        current_user: replier3,
        post_attrs: %{reply_to_id: reply1_id, post_content: %{html_body: "Nested Reply"}},
        boundary: "public"
      )

    # Create another post by a different user that replies to reply1 
    # This could potentially cause reply1 to appear twice in the feed
    {:ok, %{id: another_reply_id} = another_reply} =
      Posts.publish(
        current_user: other_user,
        post_attrs: %{
          reply_to_id: reply1_id,
          post_content: %{html_body: "Another reply to reply1"}
        },
        boundary: "public"
      )

    # Add likes/boosts that could create more activities
    {:ok, _} = Bonfire.Social.Likes.like(liker1, post)
    # {:ok, _} = Bonfire.Social.Likes.like(liker1, reply1)
    # {:ok, _} = Bonfire.Social.Likes.like(liker2, reply1)
    # {:ok, _} = Bonfire.Social.Boosts.boost(booster, reply1) # This could show reply1 again
    # {:ok, _} = Bonfire.Social.Boosts.boost(booster, reply2)

    # Like the nested reply to create more potential for duplication
    # {:ok, _} = Bonfire.Social.Likes.like(liker1, nested_reply)

    # Use :explore feed for regular feed
    {:ok, filters} = FeedLoader.preset_feed_filters(:explore, current_user: user)
    %{edges: edges} = FeedLoader.feed(filters, [])

    # Debug output to see what's actually in the feed
    flood(length(edges), "\n=== FEED CONTENTS ===")

    Enum.with_index(edges, fn edge, index ->
      object_id = edge.activity.object_id || e(edge.activity, :object, :id, nil)
      verb = edge.activity.verb_id
      subject_name = e(edge.activity, :subject, :profile, :name, nil) || "unknown"

      reply_to_info =
        case e(edge.activity, :object, :replied, :reply_to_id, nil) ||
               e(edge.activity, :replied, :reply_to_id, nil) do
          nil -> ""
          reply_to_id -> " (replying to #{reply_to_id})"
        end

      # Also check if the object itself has a reply_to context when displayed
      object_reply_context =
        case e(edge.activity, :object, :reply_to_id, nil) do
          nil -> ""
          reply_to_id -> " [object context: replying to #{reply_to_id}]"
        end

      flood(
        "#{index + 1}. #{verb} by #{subject_name} on object #{object_id}#{reply_to_info}#{object_reply_context}"
      )
    end)

    flood("==================\n")

    # Count how many times each object appears as the MAIN object 
    main_object_counts =
      Enum.reduce(edges, %{}, fn edge, acc ->
        object_id = edge.activity.object_id || e(edge.activity, :object, :id, nil)
        Map.update(acc, object_id, 1, &(&1 + 1))
      end)

    # Also track objects that appear in reply_to context or as nested context
    reply_context_objects =
      Enum.map(edges, fn edge ->
        e(edge.activity, :replied, :reply_to_id, nil) ||
          e(edge.activity, :replied, :reply_to, :id, nil) ||
          e(edge.activity, :object, :replied, :reply_to_id, nil) ||
          e(edge.activity, :object, :replied, :reply_to, :id, nil)
      end)
      |> Enum.filter(&(!is_nil(&1)))
      |> Enum.frequencies()

    flood(main_object_counts, "Main object appearances")
    flood(reply_context_objects, "Reply-to context appearances")

    # Sum the previous two counts instead of recalculating
    # Also include objects in replies_more for accurate deduplication check
    replies_more_object_ids =
      edges
      |> Enum.flat_map(fn edge ->
        Enum.map(edge.activity.replies_more || [], fn r ->
          r.object_id || e(r, :object, :id, nil)
        end)
      end)
      |> Enum.filter(& &1)

    all_object_appearances =
      Map.merge(main_object_counts, reply_context_objects, fn _k, v1, v2 -> v1 + v2 end)
      |> Map.merge(
        Enum.frequencies(replies_more_object_ids),
        fn _k, v1, v2 -> v1 + v2 end
      )

    flood(
      all_object_appearances,
      "All object appearances (including nested contexts and replies_more)"
    )

    # Check for any object appearing more than once as main object
    duplicated_objects = Enum.filter(all_object_appearances, fn {_id, count} -> count > 1 end)

    assert duplicated_objects == [],
           "No object should appear more than once as main object. Found duplicates: #{inspect(duplicated_objects)}"

    # Check for objects appearing multiple times in any context (this might catch the duplication issue)
    total_duplicated_objects =
      Enum.filter(all_object_appearances, fn {_id, count} -> count > 1 end)

    # This assertion might fail and reveal the duplication issue
    assert total_duplicated_objects == [],
           "No object should appear more than once in any context. Found duplicates: #{inspect(total_duplicated_objects)}"

    # Verify specific post only appears once as main object
    assert Map.get(all_object_appearances, post_id, 0) == 1,
           "Original post should appear at most once as main object"

    assert Map.get(all_object_appearances, reply1_id, 0) == 1,
           "Reply 1 should appear at most once as main object"

    assert Map.get(all_object_appearances, reply2_id, 0) == 1,
           "Reply 2 should appear at most once as main object"

    assert Map.get(all_object_appearances, nested_reply_id, 0) == 1,
           "Nested reply should appear at most once as main object"

    # Show only 1 reply activity for the original post (merging multiple replies)
    reply_edges =
      Enum.filter(edges, fn edge ->
        edge.activity.verb_id == Bonfire.Social.Activities.verb_id(:reply) and
          e(edge.activity, :replied, :reply_to_id, nil) == post_id
      end)

    assert length(reply_edges) == 1,
           "Should show at most 1 merged reply activity for the original post"

    if length(reply_edges) > 0 do
      main_reply = List.first(reply_edges).activity
      assert main_reply.replies_more_count == 1

      # Check that both replier1 and replier2 are present in either the main reply or replies_more
      all_reply_subject_ids =
        [main_reply.subject.id] ++
          Enum.map(main_reply.replies_more || [], fn r -> Enums.id(r.subject) end)

      assert replier1.id in all_reply_subject_ids
      assert replier2.id in all_reply_subject_ids
      assert Enum.sort([replier1.id, replier2.id]) == Enum.sort(all_reply_subject_ids)
    end

    # Verify likes/boosts are properly merged by object and verb
    like_edges = Enum.filter(edges, &(&1.activity.verb_id == "11KES1ND1CATEAM11DAPPR0VA1"))
    boost_edges = Enum.filter(edges, &(&1.activity.verb_id == "300ST0R0RANN0VCEANACT1V1TY"))

    # Check for duplicate like/boost activities on same object
    like_object_counts =
      Enum.reduce(like_edges, %{}, fn edge, acc ->
        object_id = edge.activity.object_id || e(edge.activity, :object, :id, nil)
        Map.update(acc, object_id, 1, &(&1 + 1))
      end)

    boost_object_counts =
      Enum.reduce(boost_edges, %{}, fn edge, acc ->
        object_id = edge.activity.object_id || e(edge.activity, :object, :id, nil)
        Map.update(acc, object_id, 1, &(&1 + 1))
      end)

    duplicated_likes = Enum.filter(like_object_counts, fn {_id, count} -> count > 1 end)
    duplicated_boosts = Enum.filter(boost_object_counts, fn {_id, count} -> count > 1 end)

    assert duplicated_likes == [],
           "Like activities should be merged per object. Found duplicates: #{inspect(duplicated_likes)}"

    assert duplicated_boosts == [],
           "Boost activities should be merged per object. Found duplicates: #{inspect(duplicated_boosts)}"

    # Should have merged likes for reply1 (2 likers)
    reply1_likes =
      Enum.filter(like_edges, fn edge ->
        edge.activity.object_id == reply1_id or e(edge.activity, :object, :id, nil) == reply1_id
      end)

    if length(reply1_likes) > 0 do
      like_activity = List.first(reply1_likes).activity

      subject_ids =
        Enum.map([like_activity.subject] ++ e(like_activity, :subjects_more, []), &Enums.id/1)

      assert length(subject_ids) == 2, "Should merge both likes on reply1"
    end
  end
end
