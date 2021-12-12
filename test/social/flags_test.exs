defmodule Bonfire.Social.FlagsTest do
  use Bonfire.DataCase

  alias Bonfire.Social.Flags
  alias Bonfire.Social.Posts
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Me.Fake

  test "flag works" do

    me = Fake.fake_user!()

    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs)

    assert {:ok, flag} = Flags.flag(me, flagged)
    #IO.inspect(flag)
    assert flag.flagger_id == me.id
    assert flag.flagged_id == flagged.id
  end

  test "can check if I flagged something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs)
    assert {:ok, _} = Flags.flag(me, flagged)

    assert true == Flags.flagged?(me, flagged)
  end

  test "can check if I did not flag something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs)

    assert false == Flags.flagged?(me, flagged)
  end

  test "can unflag something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs)
    assert {:ok, _} = Flags.flag(me, flagged)

    Flags.unflag(me, flagged)
    assert false == Flags.flagged?(me, flagged)
  end

  test "can list my flags" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{to_circles: [me], post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(someone, attrs)
    assert {:ok, _} = Flags.flag(me, flagged)

    assert %{edges: [fetched_flag]} = Flags.list_my(me)

    assert fetched_flag.activity.object_id == flagged.id
  end

  test "can list all flags (as an admin)" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs)
    assert {:ok, _} = Flags.flag(someone, flagged)

    assert %{edges: [fetched_flag]} = Flags.list(me)

    assert fetched_flag.activity.object_id == flagged.id
  end

  test "can list something's flaggers (as an admin)" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs)
    assert {:ok, _} = Flags.flag(someone, flagged)

    assert %{edges: fetched_flagged} = Flags.list_of(flagged, me)

    assert Enum.count(fetched_flagged, &(&1.activity.object_id == flagged.id)) == 1
  end

  test "can list someone else's flags (as an admin)" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs)
    assert {:ok, _} = Flags.flag(someone, flagged)

    assert %{edges: [fetched_flag]} = Flags.list_by(someone, me)

    assert fetched_flag.activity.object_id == flagged.id
  end

  test "see a flag of something in my notifications (as an admin)" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey you have an epic html post</p>"}}

    assert {:ok, post} = Posts.publish(me, attrs)
    assert {:ok, _} = Flags.flag(someone, post)

    assert %{edges: [fetched_flag]} = FeedActivities.feed(:notifications, me)

    assert fetched_flag.activity.object_id == post.id
  end


end
