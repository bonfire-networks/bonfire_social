defmodule Bonfire.Social.FlagsTest do

  alias Bonfire.Social.Flags
  alias Bonfire.Social.Posts
  alias Bonfire.Social.FeedActivities
  alias Bonfire.Me.Fake
  import Bonfire.Social.Utils
  use Bonfire.DataCase

  test "flag works" do

    me = Fake.fake_user!()

    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs, "public")

    assert {:ok, %{activity: activity}} = Flags.flag(me, flagged)
    # IO.inspect(activity)
    assert activity.subject.id == me.id
    assert activity.object.id == flagged.id

  end

  test "can check if I flagged something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs, "public")
    assert {:ok, _} = Flags.flag(me, flagged)

    assert true == Flags.flagged?(me, flagged)
  end

  test "can check if I did not flag something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs, "public")

    assert false == Flags.flagged?(me, flagged)
  end

  test "can unflag something" do
    me = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs, "public")
    assert {:ok, _} = Flags.flag(me, flagged)

    Flags.unflag(me, flagged)
    assert false == Flags.flagged?(me, flagged)
  end

  test "can list my flags with boundaries disabled" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(someone, attrs, "public")
    assert {:ok, flag} = Flags.flag(me, flagged)
    debug_user_circles(me)
    debug_object_acls(flag)
    assert %{edges: [fetched_flag]} = Flags.list_by(me, skip_boundary_check: true)
    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
  end

  test "can list my flags" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(someone, attrs, "public")
    assert {:ok, flag} = Flags.flag(me, flagged)
    assert %{edges: [fetched_flag]} = Flags.list_by(me)
    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
  end

  test "can list all flags (as an admin)" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs, "public")
    assert {:ok, flag} = Flags.flag(someone, flagged)

    assert %{edges: [fetched_flag]} = Flags.list_paginated(:all, me)
    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
  end

  test "can list something's flaggers (as an admin)" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs, "public")
    assert {:ok, flag} = Flags.flag(someone, flagged)

    assert %{edges: [fetched_flag]} = Flags.list_of(flagged, me)

    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
  end

  test "can list someone else's flags (as an admin)" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{summary: "summary", name: "name", html_body: "<p>epic html message</p>"}}
    assert {:ok, flagged} = Posts.publish(me, attrs, "public")
    assert {:ok, flag} = Flags.flag(someone, flagged)

    assert %{edges: [fetched_flag]} = Flags.list_by(someone, me)
    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
  end

  test "see a flag of something in my notifications (as an admin)" do
    me = Fake.fake_user!()
    someone = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey you have an epic html post</p>"}}

    assert {:ok, post} = Posts.publish(me, attrs, "public")
    assert {:ok, flag} = Flags.flag(someone, post)

    assert %{edges: [fetched_flag]} = FeedActivities.feed(:notifications, me)

    assert flag.id == fetched_flag.id
    assert flag.edge.object_id == fetched_flag.edge.object_id
    assert flag.edge.subject_id == fetched_flag.edge.subject_id
  end


end
