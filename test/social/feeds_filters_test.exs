defmodule Bonfire.Social.FeedsFiltersTest do
  use Bonfire.Social.DataCase, async: true
  use Bonfire.Common.Utils

  import Bonfire.Files.Simulation
  # import Bonfire.Federate.ActivityPub.Simulate
  alias Bonfire.Files
  alias Bonfire.Files.ImageUploader

  alias Bonfire.Social.FeedActivities
  alias Bonfire.Social.FeedLoader
  alias Bonfire.Social.Feeds
  alias Bonfire.Posts
  alias Bonfire.Messages
  alias Bonfire.Social.Objects

  alias Bonfire.Me.Users
  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake, except: [fake_remote_user!: 0]
  import Tesla.Mock
  # use Mneme

  # , capture_log: false
  # @moduletag mneme: true

  describe "reply-specific filters" do
    setup do
      user = fake_user!("main user")
      other_user = fake_user!("replier")

      # Create a root post
      root_post =
        fake_post!(user, "public", %{
          post_content: %{name: "root post", html_body: "original content"}
        })

      # Create a reply to it
      reply_post =
        fake_post!(other_user, "public", %{
          post_content: %{name: "reply post", html_body: "reply content"},
          reply_to_id: root_post.id
        })

      %{
        user: user,
        other_user: other_user,
        root_post: root_post,
        reply_post: reply_post
      }
    end

    test "can filter out replies", %{
      user: user,
      root_post: root_post,
      reply_post: reply_post
    } do
      feed = FeedLoader.feed(:local, %{exclude_activity_types: :reply}, current_user: user)

      assert FeedLoader.feed_contains?(feed, root_post, current_user: user)
      refute FeedLoader.feed_contains?(feed, reply_post, current_user: user)
    end

    test "can show only replies", %{
      user: user,
      root_post: root_post,
      reply_post: reply_post
    } do
      feed = FeedLoader.feed(:local, %{activity_types: :reply}, current_user: user)

      refute FeedLoader.feed_contains?(feed, root_post, current_user: user)
      assert FeedLoader.feed_contains?(feed, reply_post, current_user: user)
    end
  end

  describe "exclusion filters" do
    setup do
      user = fake_user!("main user")
      other_user = fake_user!("poster")

      # Create posts with different subject/object types
      post =
        fake_post!(other_user, "public", %{
          post_content: %{name: "regular post", html_body: "content"}
        })

      %{
        user: user,
        other_user: other_user,
        post: post
      }
    end

    test "exclude_subjects filters out specific subject", %{
      user: user,
      post: post,
      other_user: other_user
    } do
      feed = FeedLoader.feed(:custom, %{exclude_subjects: other_user}, current_user: user)

      refute FeedLoader.feed_contains?(feed, post, current_user: user)
    end

    test "exclude_subject_types filters out specific subject types (string)", %{
      user: user,
      post: post
    } do
      feed = FeedLoader.feed(:custom, %{exclude_subject_types: ["user"]}, current_user: user)

      refute FeedLoader.feed_contains?(feed, post, current_user: user)
    end

    test "exclude_subject_types filters out specific subject types (schema)", %{
      user: user,
      post: post
    } do
      feed =
        FeedLoader.feed(:custom, %{exclude_subject_types: [Bonfire.Data.Identity.User]},
          current_user: user
        )

      refute FeedLoader.feed_contains?(feed, post, current_user: user)
    end

    test "exclude_subject_types filters out specific subject types (schema string)", %{
      user: user,
      post: post
    } do
      feed =
        FeedLoader.feed(:custom, %{exclude_subject_types: ["Bonfire.Data.Identity.User"]},
          current_user: user
        )

      refute FeedLoader.feed_contains?(feed, post, current_user: user)
    end

    test "exclude_subject_types with invalid type (string)", %{user: user, post: post} do
      feed = FeedLoader.feed(:custom, %{exclude_subject_types: ["fdskfjk"]}, current_user: user)

      assert FeedLoader.feed_contains?(feed, post, current_user: user)
    end

    test "exclude_subject_types with invalid type (atom)", %{user: user, post: post} do
      feed = FeedLoader.feed(:custom, %{exclude_subject_types: [:testing]}, current_user: user)

      assert FeedLoader.feed_contains?(feed, post, current_user: user)
    end

    test "exclude_subject_types with invalid type (non-schema module)", %{user: user, post: post} do
      feed =
        FeedLoader.feed(:custom, %{exclude_subject_types: [Bonfire.Social]}, current_user: user)

      assert FeedLoader.feed_contains?(feed, post, current_user: user)
    end

    test "exclude_objects filters out specific object", %{user: user, post: post} do
      feed = FeedLoader.feed(:custom, %{exclude_objects: post}, current_user: user)

      refute FeedLoader.feed_contains?(feed, post, current_user: user)
    end

    test "exclude_object_types filters out specific object types", %{user: user, post: post} do
      feed = FeedLoader.feed(:custom, %{exclude_object_types: ["post"]}, current_user: user)

      refute FeedLoader.feed_contains?(feed, post, current_user: user)
    end

    test "exclude_object_types filters out specific object types (schema)", %{
      user: user,
      post: post
    } do
      feed =
        FeedLoader.feed(:custom, %{exclude_object_types: [Bonfire.Data.Social.Post]},
          current_user: user
        )

      refute FeedLoader.feed_contains?(feed, post, current_user: user)
    end

    test "exclude_object_types filters out specific object types (schema string)", %{
      user: user,
      post: post
    } do
      feed =
        FeedLoader.feed(:custom, %{exclude_object_types: ["Bonfire.Data.Social.Post"]},
          current_user: user
        )

      refute FeedLoader.feed_contains?(feed, post, current_user: user)
    end

    test "exclude_object_types with invalid type (string) is ignored", %{user: user, post: post} do
      feed = FeedLoader.feed(:custom, %{exclude_object_types: ["fdskfjk"]}, current_user: user)

      assert FeedLoader.feed_contains?(feed, post, current_user: user)
    end

    test "exclude_object_types with invalid type (atom) is ignored", %{user: user, post: post} do
      feed = FeedLoader.feed(:custom, %{exclude_object_types: [:testing]}, current_user: user)

      assert FeedLoader.feed_contains?(feed, post, current_user: user)
    end
  end

  describe "feed_ids filter" do
    setup do
      user = fake_user!("main user")
      other_user = fake_user!("poster")

      # Create multiple posts to get different feed IDs
      post1 =
        fake_post!(other_user, "public", %{
          post_content: %{name: "post 1", html_body: "content 1"}
        })

      post2 =
        fake_post!(other_user, "public", %{
          post_content: %{name: "post 2", html_body: "content 2"}
        })

      %{
        user: user,
        other_user: other_user,
        post1: post1,
        post2: post2
      }
    end

    # test "filters for specific feed IDs", %{user: user, post1: post1, post2: post2} do
    #   # Test single ID
    #   feed = FeedLoader.feed(:custom, %{feed_ids: post1.id}, current_user: user)
    #   assert FeedLoader.feed_contains?(feed, post1, current_user: user)
    #   refute FeedLoader.feed_contains?(feed, post2, current_user: user)
    #   assert length(feed.edges) == 1

    #   # Test multiple IDs
    #   feed = FeedLoader.feed(:custom, %{feed_ids: [post1.id, post2.id]}, current_user: user)
    #   assert FeedLoader.feed_contains?(feed, post1, current_user: user)
    #   assert FeedLoader.feed_contains?(feed, post2, current_user: user)
    #   assert length(feed.edges) == 2
    # end
  end

  describe "invalid and edge cases for feed IDs" do
    setup do
      user = fake_user!("main user")

      post =
        fake_post!(user, "public", %{
          post_content: %{name: "test post", html_body: "content"}
        })

      %{
        user: user,
        post: post,
        malformed_id: "not@valid#id",
        valid_feed_id: Feeds.named_feed_id(:local),
        unfiltered_feed: FeedLoader.feed(:custom, %{}, current_user: user) |> fas()
      }
    end

    defp fas(%{edges: edges}), do: Enum.map(edges, & &1.activity)

    test "handles non-feed UIDs", %{user: user, post: post, unfiltered_feed: unfiltered_feed} do
      feed = FeedLoader.feed(:custom, %{feed_ids: [post.id]}, current_user: user)
      assert FeedLoader.feed_contains?(feed, post, current_user: user)
      assert feed |> fas() == unfiltered_feed
    end

    test "handles mixed valid non-feed UID and malformed IDs", %{
      user: user,
      post: post,
      malformed_id: malformed_id,
      unfiltered_feed: unfiltered_feed
    } do
      feed = FeedLoader.feed(:custom, %{feed_ids: [post.id, malformed_id]}, current_user: user)
      assert FeedLoader.feed_contains?(feed, post, current_user: user)
      assert feed |> fas() == unfiltered_feed
    end

    test "handles mixed valid non-feed UID, malformed IDs, and valid feed IDs", %{
      user: user,
      post: post,
      valid_feed_id: valid_feed_id,
      malformed_id: malformed_id,
      unfiltered_feed: unfiltered_feed
    } do
      feed =
        FeedLoader.feed(:custom, %{feed_ids: [valid_feed_id, post.id, malformed_id]},
          current_user: user
        )

      assert FeedLoader.feed_contains?(feed, post, current_user: user)
      assert feed |> fas() == FeedLoader.feed(:custom, %{}, current_user: user) |> fas()
    end

    test "handles malformed IDs", %{
      user: user,
      malformed_id: malformed_id,
      unfiltered_feed: unfiltered_feed
    } do
      feed = FeedLoader.feed(:custom, %{feed_ids: malformed_id}, current_user: user)
      assert feed |> fas() == unfiltered_feed
    end

    test "handles empty feed_ids list", %{user: user, unfiltered_feed: unfiltered_feed} do
      feed = FeedLoader.feed(:custom, %{feed_ids: []}, current_user: user)
      assert feed |> fas() == unfiltered_feed
    end
  end

  describe "filter combinations and precedence" do
    setup do
      user = fake_user!("main user")
      other_user = fake_user!("other_user")

      # Create various types of content for testing combinations
      root_post =
        fake_post!(user, "public", %{
          post_content: %{name: "root post", html_body: "content with #test"}
        })

      reply_post =
        fake_post!(other_user, "public", %{
          post_content: %{name: "reply post", html_body: "reply content"},
          reply_to_id: root_post.id
        })

      liked_post =
        fake_post!(other_user, "public", %{
          post_content: %{name: "liked post", html_body: "liked content"}
        })

      {:ok, _like} = Bonfire.Social.Likes.like(user, liked_post)

      tagged_post =
        fake_post!(user, "public", %{
          post_content: %{name: "tagged post", html_body: "content with #important"}
        })

      %{
        user: user,
        other_user: other_user,
        root_post: root_post,
        reply_post: reply_post,
        liked_post: liked_post,
        tagged_post: tagged_post
      }
    end

    # still needed for something else?
    @tag :todo
    test "handles conflicting reply filters", %{user: user, reply_post: reply_post} do
      # should test that conflicting settings result in what?
      feed =
        FeedLoader.feed(
          :custom,
          %{
            exclude_replies: true,
            only_replies: true
          },
          current_user: user
        )

      refute FeedLoader.feed_contains?(feed, reply_post, current_user: user)
      assert feed.edges == []
    end
  end

  describe "mixed filter interactions" do
    setup do
      user = fake_user!("main user")
      other_user = fake_user!("other_user")

      # Create a post with multiple characteristics
      complex_post =
        fake_post!(other_user, "public", %{
          post_content: %{
            name: "complex post",
            html_body: "content with #test and @#{user.character.username}"
          }
        })

      {:ok, _} = Bonfire.Social.Boosts.boost(user, complex_post)

      %{
        user: user,
        other_user: other_user,
        complex_post: complex_post
      }
    end

    # fixme
    test "filter order, or use of lists or not, shouldn't affect results", %{
      user: user,
      other_user: other_user,
      complex_post: complex_post
    } do
      # Same filters, different order
      filters1 = %{
        tags: ["test"],
        activity_types: [:boost],
        subjects: [user.id]
        # creators: [other_user.id]
      }

      filters2 = %{
        # creators: other_user.id,
        subjects: user.id,
        activity_types: :boost,
        tags: "test"
      }

      feed1 = FeedLoader.feed(:custom, filters1, current_user: user)
      feed2 = FeedLoader.feed(:custom, filters2, current_user: user)

      assert FeedLoader.feed_contains?(feed1, complex_post, current_user: user)
      assert FeedLoader.feed_contains?(feed2, complex_post, current_user: user)
      # Compare paginator edges length
      assert length(feed1.edges) == length(feed2.edges)
    end
  end

  describe "origin can filter by subject" do
    setup do
      user = fake_user!("main user")
      other_user = fake_user!("other_user")

      local_post =
        fake_post!(user, "public", %{
          post_content: %{
            name: "a local post",
            html_body: "content"
          }
        })

      remote_post =
        fake_post!(other_user, "public", %{
          post_content: %{
            name: "a remote post",
            html_body: "content"
          }
        })

      instance_domain = "example.local"
      instance_url = "https://#{instance_domain}"
      actor_url = "#{instance_url}/actors/other_user"

      {:ok, instance} =
        Bonfire.Federate.ActivityPub.Instances.get_or_create(instance_url)
        |> debug("instance created")

      {:ok, peered} =
        Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(other_user, actor_url)
        |> debug("user attached to instance")

      %{
        user: user,
        other_user: other_user,
        instance_domain: instance_domain,
        instance: instance,
        local_post: local_post,
        remote_post: remote_post
      }
    end

    test "with instance/peer IDs", %{
      user: user,
      other_user: other_user,
      instance: instance,
      local_post: local_post,
      remote_post: remote_post
    } do
      feed = FeedLoader.feed(:custom, %{origin: Enums.id(instance)}, current_user: user)

      assert FeedLoader.feed_contains?(feed, remote_post, current_user: user)
      refute FeedLoader.feed_contains?(feed, local_post, current_user: user)
    end

    test "with  instance domain name", %{
      user: user,
      other_user: other_user,
      local_post: local_post,
      remote_post: remote_post,
      instance_domain: instance_domain
    } do
      feed = FeedLoader.feed(:custom, %{origin: instance_domain}, current_user: user)

      assert FeedLoader.feed_contains?(feed, remote_post, current_user: user)
      refute FeedLoader.feed_contains?(feed, local_post, current_user: user)
    end
  end

  describe "origin can filter by object" do
    setup do
      user = fake_user!("main user")
      other_user = fake_user!("other_user")

      local_post =
        fake_post!(user, "public", %{
          post_content: %{
            name: "a local post",
            html_body: "content"
          }
        })

      remote_post =
        fake_post!(other_user, "public", %{
          post_content: %{
            name: "a remote post",
            html_body: "content"
          }
        })

      instance_domain = "example.local"
      instance_url = "https://#{instance_domain}"

      {:ok, instance} =
        Bonfire.Federate.ActivityPub.Instances.get_or_create(instance_url)
        |> debug("instance created")

      post_url = "#{instance_url}/post/1"

      {:ok, peered} =
        Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(remote_post, post_url)
        |> debug("post attached to instance")

      %{
        user: user,
        other_user: other_user,
        instance_domain: instance_domain,
        instance: instance,
        local_post: local_post,
        remote_post: remote_post
      }
    end

    test "with instance/peer IDs", %{
      user: user,
      other_user: other_user,
      instance: instance,
      local_post: local_post,
      remote_post: remote_post
    } do
      feed = FeedLoader.feed(:custom, %{origin: Enums.id(instance)}, current_user: user)

      assert FeedLoader.feed_contains?(feed, remote_post, current_user: user)
      refute FeedLoader.feed_contains?(feed, local_post, current_user: user)
    end

    test "with  instance domain name", %{
      user: user,
      other_user: other_user,
      local_post: local_post,
      remote_post: remote_post,
      instance_domain: instance_domain
    } do
      feed = FeedLoader.feed(:custom, %{origin: instance_domain}, current_user: user)

      assert FeedLoader.feed_contains?(feed, remote_post, current_user: user)
      refute FeedLoader.feed_contains?(feed, local_post, current_user: user)
    end
  end
end
