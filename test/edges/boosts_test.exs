defmodule Bonfire.Social.BoostsTest do
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.Boosts
  alias Bonfire.Posts
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Me.Fake

  test "can boost, and check if I did or did not boosted something" do
    me = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, boosted} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert false == Boosts.boosted?(me, boosted)

    assert {:ok, boost} = Boosts.boost(me, boosted)

    assert boost.edge.subject_id == me.id
    assert boost.edge.object_id == boosted.id

    assert true == Boosts.boosted?(me, boosted)
  end

  test "cannot boost something repeatedly in too short a time" do
    me = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, boosted} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, boost} = Boosts.boost(me, boosted)
    assert true == Boosts.boosted?(me, boosted)

    Process.put([:bonfire_social, Bonfire.Social.Boosts, :can_reboost_after], true)

    assert {:ok, boost} = Boosts.boost(me, boosted)
    assert 2 == Boosts.count(me, boosted)

    Process.put([:bonfire_social, Bonfire.Social.Boosts, :can_reboost_after], false)

    assert {:error, _} = Boosts.boost(me, boosted)
    assert 2 == Boosts.count(me, boosted)

    Process.put([:bonfire_social, Bonfire.Social.Boosts, :can_reboost_after], 60)

    assert {:error, _} = Boosts.boost(me, boosted)
    assert 2 == Boosts.count(me, boosted)

    Process.put([:bonfire_social, Bonfire.Social.Boosts, :can_reboost_after], 0)
    Process.sleep(1000)
    assert {:ok, boost} = Boosts.boost(me, boosted)
    assert 3 == Boosts.count(me, boosted)
  end

  test "can unboost something" do
    me = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, boosted} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, boost} = Boosts.boost(me, boosted)

    Boosts.unboost(me, boosted)
    assert false == Boosts.boosted?(me, boosted)
  end

  test "can list my boosts" do
    me = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, boosted} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, boost} = Boosts.boost(me, boosted)

    assert %{edges: [fetched_boost]} = Boosts.list_my(me)

    assert fetched_boost.edge.object_id == boosted.id
  end

  test "can list something's boosters" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, boosted} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, boost} = Boosts.boost(me, boosted)
    assert {:ok, boost2} = Boosts.boost(someone, boosted)

    assert %{edges: fetched_boosted} = Boosts.list_of(boosted, me)

    assert Enum.count(fetched_boosted, &(&1.edge.object_id == boosted.id)) == 2
  end

  test "can list someone else's boosts" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        name: "name",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, boosted} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, boost} = Boosts.boost(someone, boosted)

    assert %{edges: [fetched_boost]} = Boosts.list_by(someone, me)

    assert fetched_boost.edge.object_id == boosted.id
  end

  test "see a boost of something I posted in my notifications" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()

    attrs = %{
      post_content: %{html_body: "<p>hey you have an epic html post</p>"}
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, boost} = Boosts.boost(someone, post)

    assert %{edges: [fetched_boost]} = FeedActivities.feed(:notifications, current_user: me)

    assert fetched_boost.activity.object_id == post.id
  end
end
