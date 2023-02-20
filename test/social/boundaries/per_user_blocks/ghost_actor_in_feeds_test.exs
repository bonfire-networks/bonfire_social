defmodule Bonfire.Social.Boundaries.GhostActorFeedsPerUserTest do
  use Bonfire.Social.DataCase
  import Tesla.Mock
  import Bonfire.Boundaries.Debug
  alias ActivityPub.Config
  alias Bonfire.Social.Posts
  alias Bonfire.Data.ActivityPub.Peered
  alias Bonfire.Federate.ActivityPub.Simulate

  @my_name "alice"
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

  test "shows in feeds a post with no per-user ghosting" do
    me = fake_user!(@my_name)
    other_user = fake_user!()

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

  test "does not show in my_feed a post from someone who per-user ghosted me, who I am not following" do
    me = fake_user!(@my_name)
    other_user = fake_user!()

    Bonfire.Boundaries.Blocks.block(me, :ghost, current_user: other_user)

    assert {:ok, post} =
             Posts.publish(
               current_user: other_user,
               post_attrs: @attrs,
               boundary: "public"
             )

    refute Bonfire.Social.FeedActivities.feed_contains?(:my, post, me)
  end

  test "does not show in my_feed a post from someone who per-user ghosted me, who I am following" do
    me = fake_user!(@my_name)
    other_user = fake_user!()

    Bonfire.Social.Follows.follow(me, other_user)

    Bonfire.Boundaries.Blocks.block(me, :ghost, current_user: other_user)

    assert {:ok, post} =
             Posts.publish(
               current_user: other_user,
               post_attrs: @attrs,
               boundary: "public"
             )

    refute Bonfire.Social.FeedActivities.feed_contains?(:my, post, me)
  end

  test "does not show in any feeds a post from someone who per-user ghosted me" do
    me = fake_user!(@my_name)
    other_user = fake_user!()

    Bonfire.Boundaries.Blocks.block(me, :ghost, current_user: other_user)

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

  test "does not show in any feeds a post from someone who per-user ghosted me later on" do
    me = fake_user!(@my_name)
    other_user = fake_user!()

    assert {:ok, post} =
             Posts.publish(
               current_user: other_user,
               post_attrs: @attrs,
               boundary: "public"
             )

    # check that I can see it before being ghosted
    assert Bonfire.Social.FeedActivities.feed_contains?(:local, post, current_user: me)

    Bonfire.Boundaries.Blocks.block(me, :ghost, current_user: other_user)

    refute Bonfire.Social.FeedActivities.feed_contains?(:local, post, me)
  end
end
