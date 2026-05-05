defmodule Bonfire.Social.ThreadsParticipantsTest do
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Posts
  alias Bonfire.Social.Threads
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Boundaries.Verbs
  alias Bonfire.Me.Fake

  test "list_participants returns author of a post" do
    user = Fake.fake_user!("author")

    attrs = %{
      post_content: %{
        html_body: "<p>Hello world post</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public"
             )

    participants =
      Threads.list_participants(post)
      |> debug("the part")

    assert length(participants) == 1
    first_participant = List.first(participants)
    assert first_participant.id == user.id
  end

  test "list_participants returns all participants in a thread" do
    first_user = Fake.fake_user!("first")
    second_user = Fake.fake_user!("second")
    third_user = Fake.fake_user!("third")

    # Create the original post
    attrs = %{
      post_content: %{
        html_body: "<p>Original post</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: first_user,
               post_attrs: attrs,
               boundary: "public"
             )

    # Create a reply from second user
    reply_attrs = %{
      post_content: %{
        html_body: "<p>This is a reply</p>"
      },
      reply_to_id: post.id
    }

    assert {:ok, reply} =
             Posts.publish(
               current_user: second_user,
               post_attrs: reply_attrs,
               boundary: "public"
             )

    # Create a seperate post
    attrs2 = %{
      post_content: %{
        html_body: "<p>Another post</p>"
      }
    }

    assert {:ok, post2} =
             Posts.publish(
               current_user: first_user,
               post_attrs: attrs2,
               boundary: "public"
             )

    # Create a reply from third user, in a seperate thread
    reply2_attrs = %{
      post_content: %{
        html_body: "<p>This is a seperate reply</p>"
      },
      reply_to_id: post2.id
    }

    assert {:ok, reply2} =
             Posts.publish(
               current_user: third_user,
               post_attrs: reply2_attrs,
               boundary: "public"
             )

    participants =
      Threads.list_participants(reply, post.id)
      |> debug("the part")

    participant_ids = Enum.map(participants, & &1.id)
    assert first_user.id in participant_ids
    assert second_user.id in participant_ids
    refute third_user.id in participant_ids

    assert length(participants) == 2
  end

  test "list_participants includes tagged users" do
    author = Fake.fake_user!("author")
    tagged_user = Fake.fake_user!("mentionned")
    non_tagged_user = Fake.fake_user!("non_tagged")

    # Create post with a mention
    attrs = %{
      post_content: %{
        html_body: "<p>Tagging @#{tagged_user.character.username}</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: author,
               post_attrs: attrs,
               boundary: "public"
             )

    # Create post with a mention, as a seperate thread
    attrs2 = %{
      post_content: %{
        html_body: "<p>Tagging @#{non_tagged_user.character.username}</p>"
      }
    }

    assert {:ok, post2} =
             Posts.publish(
               current_user: author,
               post_attrs: attrs2,
               boundary: "public"
             )

    participants =
      Threads.list_participants(post)
      |> debug("the part")

    # Should include both the author and the tagged user
    assert length(participants) == 2

    participant_ids = Enum.map(participants, & &1.id)
    assert author.id in participant_ids
    assert tagged_user.id in participant_ids
    refute non_tagged_user.id in participant_ids
  end

  test "list_participants handles nested replies" do
    first_user = Fake.fake_user!("first")
    second_user = Fake.fake_user!("second")
    third_user = Fake.fake_user!("third")

    # Create the original post
    attrs = %{
      post_content: %{
        html_body: "<p>Original post</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: first_user,
               post_attrs: attrs,
               boundary: "public"
             )

    # Create a reply from second user
    reply_attrs = %{
      post_content: %{
        html_body: "<p>First reply</p>"
      },
      reply_to_id: post.id
    }

    assert {:ok, reply} =
             Posts.publish(
               current_user: second_user,
               post_attrs: reply_attrs,
               boundary: "public"
             )

    # Create a nested reply from third user
    nested_reply_attrs = %{
      post_content: %{
        html_body: "<p>Nested reply</p>"
      },
      reply_to_id: reply.id
    }

    assert {:ok, nested_reply} =
             Posts.publish(
               current_user: third_user,
               post_attrs: nested_reply_attrs,
               boundary: "public"
             )

    participants =
      Threads.list_participants(nested_reply, post.id)
      |> debug("the part")

    assert length(participants) == 3

    participant_ids = Enum.map(participants, & &1.id)
    assert first_user.id in participant_ids
    assert second_user.id in participant_ids
    assert third_user.id in participant_ids
  end

  test "list_participants respects the limit option" do
    author = Fake.fake_user!("author")

    # Create several users to tag
    tagged_users = for i <- 1..5, do: Fake.fake_user!("user_#{i}")

    # Create a post mentioning all users
    mentions = Enum.map(tagged_users, fn user -> "@#{user.character.username}" end)
    mentions_text = Enum.join(mentions, " ")

    attrs = %{
      post_content: %{
        html_body: "<p>Tagging #{mentions_text}</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: author,
               post_attrs: attrs,
               boundary: "public"
             )

    # Get participants with a limit of 3
    participants = Threads.list_participants(post, nil, limit: 3)

    # Should respect the limit (but we can't be sure which 3 participants will be included)
    assert length(participants) == 3
  end

  test "list_participants excludes hashtags and categories" do
    user = Fake.fake_user!()

    # Create a post with hashtags
    attrs = %{
      post_content: %{
        html_body: "<p>Post with #hashtag and @#{user.character.username}</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public"
             )

    participants = Threads.list_participants(post)

    # Should only include the user, not the hashtag
    assert length(participants) == 1

    # Verify that all participants are users
    participant_types = Enum.map(participants, & &1.__struct__)

    assert Enum.all?(participant_types, fn type ->
             type != Bonfire.Tag.Hashtag && type != Bonfire.Classify.Category
           end)
  end

  test "list_participants returns an empty list for non-existent thread" do
    # Testing with nil thread ID
    participants = Threads.list_participants(nil)
    assert participants == []

    # Testing with non-existent ID
    participants = Threads.list_participants("non_existent_id")
    assert participants == []
  end

  test "list_participants for an activity" do
    user = Fake.fake_user!("author")

    attrs = %{
      post_content: %{
        html_body: "<p>Test post</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public"
             )

    participants = Threads.list_participants(post.activity)

    assert length(participants) == 1
    assert List.first(participants).id == user.id
  end

  test "list_participants does not include quoted posts attached as tags" do
    author = Fake.fake_user!("quoter")
    other = Fake.fake_user!("quoted_author")

    # Original post that will be quoted
    {:ok, original} =
      Posts.publish(
        current_user: other,
        post_attrs: %{post_content: %{html_body: "<p>original</p>"}},
        boundary: "public"
      )

    # Quote post
    {:ok, quote_post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "<p>quoting</p>"}},
        boundary: "public"
      )

    # Simulate the quote relationship the same way `Bonfire.Social.Quotes.update_quote_add/4` does
    {:ok, _} = Bonfire.Tag.tag_something(author, quote_post, [original], :skip_boundary_check)

    quote_post = Bonfire.Common.Repo.maybe_preload(quote_post, tags: [:character])

    participants = Threads.list_participants(quote_post)
    participant_ids = Enum.map(participants, & &1.id)

    # The quote author should be a participant
    assert author.id in participant_ids
    # The quoted post must NOT be listed as a participant (the bug)
    refute original.id in participant_ids
    # And no participant entry should be missing user data
    assert Enum.all?(participants, &(not is_nil(e(&1, :character, nil))))
  end

  test "list_participants_for_threads excludes boost-activity subjects from edges" do
    author = Fake.fake_user!("author")
    booster = Fake.fake_user!("booster")

    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "<p>boost me</p>"}},
        boundary: "public"
      )

    thread_id = e(post, :replied, :thread_id, nil) || post.id
    create_verb_id = Verbs.get_id!(:create)
    boost_verb_id = Verbs.get_id!(:boost)

    edges = [
      %{
        activity: %{
          replied: %{thread_id: thread_id},
          subject: author,
          subject_id: author.id,
          verb_id: create_verb_id,
          object_id: post.id,
          object: %{tags: []}
        }
      },
      %{
        activity: %{
          replied: %{thread_id: thread_id},
          subject: booster,
          subject_id: booster.id,
          verb_id: boost_verb_id,
          object_id: post.id,
          object: %{tags: []}
        }
      }
    ]

    result = Threads.list_participants_for_threads(edges, skip_boundary_check: true)
    participant_ids = Map.get(result, thread_id, []) |> Enum.map(&id/1)

    assert author.id in participant_ids
    refute booster.id in participant_ids
  end

  test "list_participants_for_threads excludes non-user tags (e.g. quoted posts) from edges" do
    author = Fake.fake_user!("author")
    mentioned = Fake.fake_user!("mentioned")

    {:ok, post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "<p>hi</p>"}},
        boundary: "public"
      )

    {:ok, quoted_post} =
      Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "<p>target</p>"}},
        boundary: "public"
      )

    thread_id = e(post, :replied, :thread_id, nil) || post.id
    create_verb_id = Verbs.get_id!(:create)

    edges = [
      %{
        activity: %{
          replied: %{thread_id: thread_id},
          subject: author,
          subject_id: author.id,
          verb_id: create_verb_id,
          object_id: post.id,
          # Mix a real user tag (a mention) and a non-user tag (the quoted post)
          object: %{tags: [mentioned, quoted_post]}
        }
      }
    ]

    result = Threads.list_participants_for_threads(edges, skip_boundary_check: true)
    participant_ids = Map.get(result, thread_id, []) |> Enum.map(&id/1)

    assert author.id in participant_ids
    assert mentioned.id in participant_ids
    refute quoted_post.id in participant_ids
  end
end
