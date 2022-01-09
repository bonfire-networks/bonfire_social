defmodule Bonfire.Social.FollowsTest do
  use Bonfire.DataCase

  alias Bonfire.Social.{Follows, FeedActivities}
  alias Bonfire.Me.Fake

  test "follow works" do

    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, %{activity: activity}} = Follows.follow(me, followed)
    # IO.inspect(activity)
    assert activity.subject.id == me.id
    assert activity.object.id == followed.id
  end

  test "can get my follow" do
    me = Fake.fake_user!()
    followed = Fake.fake_user!()
    assert {:ok, follow} = Follows.follow(me, followed)

    assert {:ok, fetched_follow} = Follows.get(me, followed)

    assert fetched_follow == follow.id
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

  test "can list my followers" do
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

    follower = Fake.fake_user!("follower")
    followed = Fake.fake_user!("followed")
    assert {:ok, follow} = Follows.follow(follower, followed)

    assert %{edges: [fetched_follow]} = Follows.list_followers(followed, follower)
    assert fetched_follow.id == follow.id

    assert %{edges: fetched} = p = FeedActivities.feed(:notifications, followed)
    # IO.inspect(notifications: p)
    assert %{} = notification = List.first(fetched)
    assert activity = notification.activity |> Bonfire.Repo.maybe_preload([object: [:profile]])
    # IO.inspect(followed: followed)
    # IO.inspect(notifications: activity)

    assert activity.object_id == followed.id
  end

end
