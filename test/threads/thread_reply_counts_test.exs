defmodule Bonfire.Social.Threads.ReplyCountsTest do
  @moduledoc """
  The denormalised reply counts on the `Replied` mixin (maintained by the `bonfire_data_social_replied_trigger`) must stay accurate when replies are deleted, not just when they are created.
  """

  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Data.Social.Replied
  alias Bonfire.Posts
  alias Bonfire.Social.Objects
  alias Bonfire.Me.Fake

  setup do
    alice = Fake.fake_user!("alice")

    {:ok, op} =
      Posts.publish(
        current_user: alice,
        post_attrs: %{post_content: %{html_body: "<p>OP</p>"}},
        boundary: "public"
      )

    {:ok, alice: alice, op: op}
  end

  defp publish_reply(user, reply_to_id, body) do
    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{
          post_content: %{html_body: "<p>#{body}</p>"},
          reply_to_id: reply_to_id
        },
        boundary: "public"
      )

    post
  end

  # re-read the mixin row rather than re-preloading a struct we already hold, so we can never assert against a stale in-memory copy
  defp counts(object) do
    %Replied{} = replied = repo().get(Replied, id(object))

    %{
      direct: replied.direct_replies_count,
      nested: replied.nested_replies_count,
      total: replied.total_replies_count
    }
  end

  test "deleting a direct reply decrements the parent's reply counts", %{alice: alice, op: op} do
    reply = publish_reply(alice, op.id, "a reply")

    # precondition: the insert trigger actually counted it, so a later 0 means the delete did something
    assert %{direct: 1, total: 1} = counts(op)

    assert {:ok, _} = Objects.delete(reply, current_user: alice)

    assert %{direct: 0, nested: 0, total: 0} = counts(op)
  end

  test "deleting a nested reply decrements both its parent and the thread root", %{
    alice: alice,
    op: op
  } do
    reply = publish_reply(alice, op.id, "a reply")
    sub_reply = publish_reply(alice, reply.id, "a sub-reply")

    assert %{direct: 1, nested: 1, total: 2} = counts(op)
    assert %{direct: 1, total: 1} = counts(reply)

    assert {:ok, _} = Objects.delete(sub_reply, current_user: alice)

    assert %{direct: 1, nested: 0, total: 1} = counts(op)
    assert %{direct: 0, nested: 0, total: 0} = counts(reply)
  end

  test "deleting a mid-thread reply decrements by one and keeps its surviving children counted",
       %{alice: alice, op: op} do
    reply = publish_reply(alice, op.id, "a reply")
    _sub_reply = publish_reply(alice, reply.id, "a sub-reply")

    assert %{direct: 1, nested: 1, total: 2} = counts(op)

    assert {:ok, _} = Objects.delete(reply, current_user: alice)

    # the grandchild still exists, so it must still be counted in the root's nested total
    assert %{direct: 0, nested: 1, total: 1} = counts(op)
  end
end
