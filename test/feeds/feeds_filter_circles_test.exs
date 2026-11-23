defmodule Bonfire.Social.FeedsCirclesFilterTest do
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

  alias Bonfire.Boundaries.Circles

  alias Bonfire.Me.Users
  alias Bonfire.Me.Fake
  import Bonfire.Social.Fake
  import Bonfire.Posts.Fake, except: [fake_remote_user!: 0]
  import Tesla.Mock
  # use Mneme

  # , capture_log: false
  # @moduletag mneme: true

  describe "circle inclusion and exclusion filters" do
    setup do
      # Nothing here is about federation, but creating a post still runs the Federate act, which looks up a federation module for `{:create, Post}` through a CACHE (`ExtensionBehaviour.apply_modules_cached/2`). Under a loaded parallel run that entry can be missing, and the lookup then raises "No FederationModules or SchemaModules were defined" from inside the federating Task, killing the test. Same reason the sibling feed/group tests turn it off.
      Process.put(:federating, false)

      # Create users
      me = fake_user!("main me")
      alice = fake_user!("alice")
      bob = fake_user!("bob")
      carl = fake_user!("carl")

      # Create a circle and a me to it
      {:ok, circle} = Circles.create(me, %{named: %{name: "friends"}})
      {:ok, _} = Circles.add_to_circles(alice, circle, skip_boundary_check: true)

      # Create posts by different users
      post_by_alice = fake_post!(alice, "public", %{post_content: %{name: "post by alice"}})
      post_by_bob = fake_post!(bob, "public", %{post_content: %{name: "post by bob"}})
      post_by_carl = fake_post!(carl, "public", %{post_content: %{name: "post by carl"}})

      %{
        me: me,
        circle: circle,
        alice: alice,
        bob: bob,
        carl: carl,
        post_by_alice: id(post_by_alice),
        post_by_bob: id(post_by_bob),
        post_by_carl: id(post_by_carl)
      }
    end

    test "`subject_circles` only includes posts from members of a circle", %{
      me: me,
      circle: circle,
      post_by_alice: post_by_alice,
      # post_by_bob: post_by_bob,
      post_by_carl: post_by_carl
    } do
      # Load a feed including only posts by members of the "friends" circle
      feed = FeedLoader.feed(:custom, %{subject_circles: [circle]}, current_user: me)

      # Assert posts by Alice (members of the circle) are included
      assert FeedLoader.feed_contains?(feed, post_by_alice, current_user: me)

      # Assert posts by Carl (not in the circle) are excluded
      refute FeedLoader.feed_contains?(feed, post_by_carl, current_user: me)
    end

    test "`exclude_subject_circles` filters out posts from members of a circle", %{
      me: me,
      circle: circle,
      post_by_alice: post_by_alice,
      # post_by_bob: post_by_bob,
      post_by_carl: post_by_carl
    } do
      # Load a feed excluding posts by members of the "friends" circle
      feed = FeedLoader.feed(:custom, %{exclude_subject_circles: [circle]}, current_user: me)

      # Assert posts by Alice (member of the circle) are excluded
      refute FeedLoader.feed_contains?(feed, post_by_alice, current_user: me)

      # Assert posts by Carl (not in the circle) are included
      assert FeedLoader.feed_contains?(feed, post_by_carl, current_user: me)
    end

    # TODO: optimise query with a special case that uses the same join for both?
    test "`exclude_subject_circles` and `subject_circles` together prioritize exclusions", %{
      me: me,
      carl: carl,
      circle: circle,
      post_by_alice: post_by_alice,
      post_by_bob: post_by_bob,
      post_by_carl: post_by_carl
    } do
      {:ok, _} = Circles.add_to_circles(carl, circle, skip_boundary_check: true)

      # Create another circle and add Carl to it
      {:ok, second_circle} = Circles.create(me, %{named: %{name: "coworkers"}})
      {:ok, _} = Circles.add_to_circles(carl, second_circle, skip_boundary_check: true)

      # Load a feed that includes "friends" circle but excludes "coworkers" circle
      feed =
        FeedLoader.feed(
          :custom,
          %{subject_circles: [circle], exclude_subject_circles: [second_circle]},
          current_user: me
        )

      # Assert posts by Alice (member of "friends" circle) are included
      assert FeedLoader.feed_contains?(feed, post_by_alice, current_user: me)

      # Assert Carl's post is excluded because he is in "coworkers" circle
      refute FeedLoader.feed_contains?(feed, post_by_carl, current_user: me)

      # Assert posts by Bob are excluded because they are not in the included circle
      refute FeedLoader.feed_contains?(feed, post_by_bob, current_user: me)
    end
  end

  # A circle filter only reads circles the viewer may read (`Circles.readable_ids/2`): filtering by someone else's list or block circle would show who is in it
  describe "circle filters with a circle the viewer cannot read" do
    setup do
      Process.put(:federating, false)

      me = fake_user!("main me")
      alice = fake_user!("alice")
      bob = fake_user!("bob")
      carl = fake_user!("carl")

      # bob's own circle, holding alice; me may not read it
      {:ok, bobs_circle} = Circles.create(bob, %{named: %{name: "bob's secret list"}})
      {:ok, _} = Circles.add_to_circles(alice, bobs_circle, skip_boundary_check: true)

      post_by_alice = fake_post!(alice, "public", %{post_content: %{name: "post by alice"}})
      post_by_carl = fake_post!(carl, "public", %{post_content: %{name: "post by carl"}})

      %{
        me: me,
        alice: alice,
        bobs_circle: bobs_circle,
        post_by_alice: id(post_by_alice),
        post_by_carl: id(post_by_carl)
      }
    end

    test "`subject_circles` with someone else's circle shows nothing, not that circle's members nor the whole feed",
         %{
           me: me,
           bobs_circle: bobs_circle,
           post_by_alice: post_by_alice,
           post_by_carl: post_by_carl
         } do
      feed = FeedLoader.feed(:custom, %{subject_circles: [id(bobs_circle)]}, current_user: me)

      refute FeedLoader.feed_contains?(feed, post_by_alice, current_user: me)
      refute FeedLoader.feed_contains?(feed, post_by_carl, current_user: me)
    end

    test "`exclude_subject_circles` with someone else's circle excludes no one", %{
      me: me,
      bobs_circle: bobs_circle,
      post_by_alice: post_by_alice,
      post_by_carl: post_by_carl
    } do
      feed =
        FeedLoader.feed(:custom, %{exclude_subject_circles: [id(bobs_circle)]}, current_user: me)

      assert FeedLoader.feed_contains?(feed, post_by_alice, current_user: me)
      assert FeedLoader.feed_contains?(feed, post_by_carl, current_user: me)
    end

    # a caller that already skips boundaries (an admin or system load) filters by any circle
    test "`subject_circles` with someone else's circle still narrows the feed when the caller skips boundary checks",
         %{
           me: me,
           bobs_circle: bobs_circle,
           post_by_alice: post_by_alice,
           post_by_carl: post_by_carl
         } do
      feed =
        FeedLoader.feed(:custom, %{subject_circles: [id(bobs_circle)]},
          current_user: me,
          skip_boundary_check: true
        )

      assert FeedLoader.feed_contains?(feed, post_by_alice, current_user: me)
      refute FeedLoader.feed_contains?(feed, post_by_carl, current_user: me)
    end

    # control: the reader's own followed circle (what notification audiences use via `:my_followed`) stays readable
    test "`exclude_subject_circles` with the viewer's own followed circle still excludes who they follow",
         %{
           me: me,
           alice: alice,
           post_by_alice: post_by_alice,
           post_by_carl: post_by_carl
         } do
      {:ok, _} = Bonfire.Social.Graph.Follows.follow(me, alice)
      followed = Circles.stereotype_circle_ids_for(me, [:followed])
      assert followed != []

      feed = FeedLoader.feed(:custom, %{exclude_subject_circles: followed}, current_user: me)

      refute FeedLoader.feed_contains?(feed, post_by_alice, current_user: me)
      assert FeedLoader.feed_contains?(feed, post_by_carl, current_user: me)
    end
  end
end
