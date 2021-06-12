defmodule Bonfire.Social.BoostsTest do
  use Bonfire.DataCase

  alias Bonfire.Social.Boosts
  alias Bonfire.Social.Posts
  alias Bonfire.Me.Fake

  test "boost works" do

    me = Fake.fake_user!()

    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, boosted} = Posts.publish(me, attrs)

    assert {:ok, boost} = Boosts.boost(me, boosted)
    #IO.inspect(boost)
    assert boost.booster_id == me.id
    assert boost.boosted_id == boosted.id
  end

  test "can check if I boosted something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, boosted} = Posts.publish(me, attrs)
    assert {:ok, boost} = Boosts.boost(me, boosted)

    assert true == Boosts.boosted?(me, boosted)
  end

  test "can check if I did not boost something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, boosted} = Posts.publish(me, attrs)

    assert false == Boosts.boosted?(me, boosted)
  end

  test "can unboost something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, boosted} = Posts.publish(me, attrs)
    assert {:ok, boost} = Boosts.boost(me, boosted)

    Boosts.unboost(me, boosted)
    assert false == Boosts.boosted?(me, boosted)
  end

  test "can list my boosts" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, boosted} = Posts.publish(me, attrs)
    assert {:ok, boost} = Boosts.boost(me, boosted)

    assert %{entries: [fetched_boost]} = Boosts.list_my(me)

    assert fetched_boost.activity.object_id == boosted.id
  end

  test "can list something's boosters" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, boosted} = Posts.publish(me, attrs)
    assert {:ok, boost} = Boosts.boost(me, boosted)
    assert {:ok, boost2} = Boosts.boost(someone, boosted)

    assert %{entries: fetched_boosted} = Boosts.list_of(boosted, me)

    assert Enum.count(fetched_boosted, &(&1.activity.object_id == boosted.id)) == 2
  end

  test "can list someone else's boosts" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, boosted} = Posts.publish(me, attrs)
    assert {:ok, boost} = Boosts.boost(someone, boosted)

    assert %{entries: [fetched_boost]} = Boosts.list_by(someone, me)

    assert fetched_boost.activity.object_id == boosted.id
  end

end
