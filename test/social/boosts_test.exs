defmodule Bonfire.Social.BoostsTest do
  use Bonfire.DataCase

  alias Bonfire.Social.Boosts
  alias Bonfire.Social.Posts
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Me.Fake

  test "boost works" do

    me = Fake.fake_user!()

    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, boosted} = Posts.publish(me, attrs, "public")

    assert {:ok, %{edge: edge}} = Boosts.boost(me, boosted)
    # IO.inspect(activity)
    assert edge.subject_id == me.id
    assert edge.object_id == boosted.id
  end

  test "can check if I boosted something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, boosted} = Posts.publish(me, attrs, "public")
    assert {:ok, boost} = Boosts.boost(me, boosted)

    assert true == Boosts.boosted?(me, boosted)
  end

  test "can check if I did not boost something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, boosted} = Posts.publish(me, attrs, "public")

    assert false == Boosts.boosted?(me, boosted)
  end

  test "can unboost something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, boosted} = Posts.publish(me, attrs, "public")
    assert {:ok, boost} = Boosts.boost(me, boosted)

    Boosts.unboost(me, boosted)
    assert false == Boosts.boosted?(me, boosted)
  end

  test "can list my boosts" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, boosted} = Posts.publish(me, attrs, "public")
    assert {:ok, boost} = Boosts.boost(me, boosted)

    assert %{edges: [fetched_boost]} = Boosts.list_my(me)

    assert fetched_boost.edge.object_id == boosted.id
  end

  test "can list something's boosters" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, boosted} = Posts.publish(me, attrs, "public")
    assert {:ok, boost} = Boosts.boost(me, boosted)
    assert {:ok, boost2} = Boosts.boost(someone, boosted)

    assert %{edges: fetched_boosted} = Boosts.list_of(boosted, me)

    assert Enum.count(fetched_boosted, &(&1.edge.object_id == boosted.id)) == 2
  end

  test "can list someone else's boosts" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, boosted} = Posts.publish(me, attrs, "public")
    assert {:ok, boost} = Boosts.boost(someone, boosted)

    assert %{edges: [fetched_boost]} = Boosts.list_by(someone, me)

    assert fetched_boost.edge.object_id == boosted.id
  end

  test "see a boost of something I posted in my notifications" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey you have an epic html post</p>"}}

    assert {:ok, post} = Posts.publish(me, attrs, "public")
    assert {:ok, boost} = Boosts.boost(someone, post)

    assert %{edges: [fetched_boost, _]} = FeedActivities.feed(:notifications, me)

    assert fetched_boost.activity.object_id == post.id
  end


end
