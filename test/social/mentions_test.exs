defmodule Bonfire.Social.MentionsTest do
  use Bonfire.DataCase

  alias Bonfire.Social.Posts
  alias Bonfire.Me.Fake

  test "can post with a mention" do

    me = Fake.fake_user!()
    mentioned = Fake.fake_user!()
    attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}
    assert {:ok, mention} = Posts.publish(me, attrs)
    IO.inspect(mention)
    assert mention.activity.activity.object.created.creator_id == me.id
    # assert mention.mentioned_id == mentioned.id # todo check if received
  end

  # test "can fetch mentions" do
  #   me = Fake.fake_user!()
  #   mentioned = Fake.fake_user!()
  #   attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}
  #   assert {:ok, mention} = Posts.publish(me, attrs)

  #   assert {:ok, fetched_mention} = Posts.read(me, mentioned)

  #   assert fetched_mention == mention.id
  # end

  # test "can check if mentioning someone" do
  #   me = Fake.fake_user!()
  #   mentioned = Fake.fake_user!()
  #   attrs = %{post_content: %{html_body: "<p>hey @#{mentioned.character.username} you have an epic html message</p>"}}
  #   assert {:ok, mention} = Posts.publish(me, attrs)

  #   # assert true == Mentions.mentioning?(me, mentioned)
  # end


end
