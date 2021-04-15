defmodule Bonfire.Social.MentionsTest do
  use Bonfire.DataCase

  alias Bonfire.Social.Posts
  alias Bonfire.Me.Fake

  test "mention works" do

    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    assert {:ok, mention} = Posts.publish(user, attrs)
    #IO.inspect(mention)
    assert mention.mentioner_id == me.id
    assert mention.mentioned_id == mentioned.id
  end

  test "can fetch mentions" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    assert {:ok, mention} = Posts.publish(user, attrs)

    assert {:ok, fetched_mention} = Posts.read(me, mentioned)

    assert fetched_mention == mention.id
  end

  test "can check if mentioning someone" do
    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    assert {:ok, mention} = Posts.publish(user, attrs)

    # assert true == Mentions.mentioning?(me, mentioned)
  end


end
