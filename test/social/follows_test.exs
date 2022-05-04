defmodule Bonfire.Social.FollowsTest do
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.{Follows, FeedActivities}
  alias Bonfire.Me.Fake

  test "can follow" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, %{edge: edge} = follow} = Follows.follow(me, followed)
    # debug(follow)
    # debug(activity)
    assert edge.subject_id == me.id
    assert edge.object_id == followed.id
  end

  test "can get my follow, ignoring boundary checks" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(me, followed)

    assert {:ok, fetched_follow} = Follows.get(me, followed, skip_boundary_check: true)

    assert fetched_follow.id == follow.id
  end

  test "can get my follow" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(me, followed)

    assert {:ok, fetched_follow} = Follows.get(me, followed)

    assert fetched_follow.id == follow.id
  end

  test "can check if I am following someone" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(me, followed)

    assert true == Follows.following?(me, followed)
  end

  test "can check if I am not following someone" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()

    assert false == Follows.following?(me, followed)
  end

  test "can unfollow someone" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(me, followed)

    Follows.unfollow(me, followed)
    assert false == Follows.following?(me, followed)
  end

  test "can list my followed" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(me, followed)

    assert %{edges: [fetched_follow]} = Follows.list_my_followed(me)

    assert fetched_follow.id == follow.id
  end

  test "can list my followers, ignoring boundaries" do
    me = Fake.fake_user!()
    follower = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(follower, me)

    assert %{edges: [fetched_follow]} =
      Follows.list_my_followers(current_user: me, skip_boundary_check: true)

    assert fetched_follow.id == follow.id
  end

  test "can list my followers, with boundaries enforced" do
    me = Fake.fake_user!()
    follower = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(follower, me)

    assert %{edges: [fetched_follow]} = Follows.list_my_followers(me)

    assert fetched_follow.id == follow.id
  end


  test "can list someone's followers" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(me, someone)

    assert %{edges: [fetched_follow]} = Follows.list_followers(someone, me)

    assert fetched_follow.id == follow.id
  end

  test "can list someone's followed" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(me, someone)

    assert %{edges: [fetched_follow]} = Follows.list_followers(someone, me)
    assert fetched_follow.id == follow.id
  end

  test "follow appears in followed's notifications" do

    follower = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(follower, followed)

    assert %{edges: [fetched_follow]} = Follows.list_followers(followed, follower)
    assert fetched_follow.id == follow.id

    assert %{edges: fetched} = p = FeedActivities.feed(:notifications, current_user: followed)
    # debug(notifications: p)
    assert %{} = notification = List.first(fetched)
    assert activity = notification.activity |> Bonfire.Common.Repo.maybe_preload([object: [:profile]])
    # debug(followed: followed)
    # debug(notifications: activity)

    assert activity.object_id == followed.id
  end

end
