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
      # Create users
      me = fake_user!("main me")
      alice = fake_user!("alice")
      bob = fake_user!("bob")
      carl = fake_user!("carl")

      # Create a circle and a me to it
      {:ok, circle} = Circles.create(me, %{named: %{name: "friends"}})
      {:ok, _} = Circles.add_to_circles(alice, circle)

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
      {:ok, _} = Circles.add_to_circles(carl, circle)

      # Create another circle and add Carl to it
      {:ok, second_circle} = Circles.create(me, %{named: %{name: "coworkers"}})
      {:ok, _} = Circles.add_to_circles(carl, second_circle)

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
end
