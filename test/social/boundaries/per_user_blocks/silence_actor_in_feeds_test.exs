defmodule Bonfire.Social.Boundaries.SilenceActorFeedsPerUserTest do
  use Bonfire.Social.DataCase
  import Tesla.Mock
  import Bonfire.Boundaries.Debug
  alias ActivityPub.Config
  alias Bonfire.Social.Posts
  alias Bonfire.Data.ActivityPub.Peered
  alias Bonfire.Federate.ActivityPub.Simulate

  @my_name "alice"
  @other_name "bob"
  @attrs %{
    post_content: %{
      summary: "summary",
      name: "name",
      html_body: "<p>epic html message</p>"
    }
  }

  setup_all do
    # TODO: move this into fixtures
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)
  end

  test "shows in feeds a post with no per-user silencing" do
    me = fake_user!(@my_name)
    other_user = fake_user!(@other_name)

    assert {:ok, post} =
             Posts.publish(
               current_user: other_user,
               post_attrs: @attrs,
               boundary: "public"
             )

    feed_id = Bonfire.Social.Feeds.named_feed_id(:local)
    # |> debug()
    assert Bonfire.Social.FeedActivities.feed_contains?(feed_id, post, current_user: me)
  end

  test "does not show in my_feed a post from a per-user silenced user that I am not following" do
    me = fake_user!(@my_name)
    other_user = fake_user!(@other_name)

    Bonfire.Boundaries.Blocks.block(other_user, :silence, current_user: me)

    assert {:ok, post} =
             Posts.publish(
               current_user: other_user,
               post_attrs: @attrs,
               boundary: "public"
             )

    refute Bonfire.Social.FeedActivities.feed_contains?(:my, post, me)
  end

  test "does not show in my_feed a post from a per-user silenced user that I am following" do
    me = fake_user!(@my_name)
    other_user = fake_user!(@other_name)

    Bonfire.Social.Follows.follow(me, other_user)

    Bonfire.Boundaries.Blocks.block(other_user, :silence, current_user: me)

    # Bonfire.Boundaries.Circles.get_stereotype_circles(me, [:silence_me])
    # |> Bonfire.Common.Repo.maybe_preload(caretaker: [:profile], encircles: [subject: [:profile]])
    # |> info("me: silence_me encircles")

    # Bonfire.Boundaries.Circles.get_stereotype_circles(me, [:silence_them])
    # |> Bonfire.Common.Repo.maybe_preload(caretaker: [:profile], encircles: [subject: [:profile]])
    # |> info("me: silence_them encircles")

    # Bonfire.Boundaries.Circles.get_stereotype_circles(other_user, [:silence_me])
    # |> Bonfire.Common.Repo.maybe_preload(caretaker: [:profile], encircles: [subject: [:profile]])
    # |> info("other_user: silence_me encircles")

    # Bonfire.Boundaries.Circles.get_stereotype_circles(other_user, [:silence_them])
    # |> Bonfire.Common.Repo.maybe_preload(caretaker: [:profile], encircles: [subject: [:profile]])
    # |> info("other_user: silence_them encircles")

    assert {:ok, post} =
             Posts.publish(
               current_user: other_user,
               post_attrs: @attrs,
               boundary: "public"
             )

    refute Bonfire.Social.FeedActivities.feed_contains?(:my, post, me)
  end

  test "does not show in any feeds a post from a per-user silenced user" do
    me = fake_user!(@my_name)
    other_user = fake_user!(@other_name)

    Bonfire.Boundaries.Blocks.block(other_user, :silence, current_user: me)

    # debug_user_acls(me, "me")
    # debug_user_acls(me, "other_user")

    assert {:ok, post} =
             Posts.publish(
               current_user: other_user,
               post_attrs: @attrs,
               boundary: "public"
             )

    debug_object_acls(post)

    refute Bonfire.Social.FeedActivities.feed_contains?(:local, post, me)

    third_user = fake_user!()
    # check that we do show it to others
    assert Bonfire.Social.FeedActivities.feed_contains?(:local, post, current_user: third_user)
  end

  test "does not show in any feeds a post from an user that was per-user silenced later on" do
    me = fake_user!(@my_name)
    other_user = fake_user!(@other_name)

    assert {:ok, post} =
             Posts.publish(
               current_user: other_user,
               post_attrs: @attrs,
               boundary: "public"
             )

    Bonfire.Boundaries.Blocks.block(other_user, :silence, current_user: me)

    refute Bonfire.Social.FeedActivities.feed_contains?(:local, post, me)

    # check that we do show it to others
    third = fake_user!()

    assert Bonfire.Social.FeedActivities.feed_contains?(:local, post, current_user: third)
  end
end
