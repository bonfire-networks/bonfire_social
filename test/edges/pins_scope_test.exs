defmodule Bonfire.Social.PinsScopeTest do
  @moduledoc "A pin's scope becomes the pin's subject, and federates as that actor's `featured` collection. So pinning into a scope must be something the pinner may do in that scope, not only something they may do to the object."
  use Bonfire.Social.DataCase

  alias Bonfire.Social.Pins
  alias Bonfire.Posts

  defp publish_post(user, body) do
    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: body}},
        boundary: "public"
      )

    post
  end

  defp featured_adds(user) do
    target = ActivityPub.Utils.collection_ap_id("featured", user.id)

    repo().all(
      Ecto.Query.from(o in ActivityPub.Object,
        where:
          fragment("?->>'type' = ?", o.data, "Add") and
            fragment("?->>'target' = ?", o.data, ^target)
      )
    )
  end

  test "a user can't pin into another user's scope" do
    author = fake_user!(fake_account!())
    pinner = fake_user!(fake_account!())
    victim = fake_user!(fake_account!())

    # public, so the pinner passes the `:boost` check on the object and only the scope is in question
    post = publish_post(author, "<p>someone else's post</p>")

    # a bare id, as `Pins.LiveHandler.scoped/1` passes it. Today federating that unloaded scope raises in test (`is_local?` wants `:peered` preloaded) after the pin is stored, so the raise is caught to check what was stored
    result =
      try do
        Pins.pin(pinner, post, id(victim))
      rescue
        e -> {:raised, e}
      end

    refute Pins.pinned?(victim, post)
    assert {:error, _} = result

    assert Pins.collection_items(%{
             data: %{"id" => ActivityPub.Utils.collection_ap_id("featured", victim.id)}
           }) == []

    assert featured_adds(victim) == []
  end

  describe "who may pin into a scope" do
    setup do
      # federating a bare-id scope raises in test (see above); these tests are about permission, not federation
      Process.put(:federating, false)

      author = fake_user!(fake_account!())
      replier = fake_user!(fake_account!())
      bystander = fake_user!(fake_account!())

      root = publish_post(author, "<p>a question</p>")

      {:ok, reply} =
        Posts.publish(
          current_user: replier,
          post_attrs: %{reply_to_id: id(root), post_content: %{html_body: "<p>an answer</p>"}},
          boundary: "public"
        )

      %{author: author, bystander: bystander, root: root, reply: reply}
    end

    # the Mastodon API pins this way (`social_masto_adapter.ex`)
    test "pinning to your own profile works without a scope", %{bystander: user, root: post} do
      assert {:ok, _} = Pins.pin(user, post)
      assert Pins.pinned?(user, post)
    end

    test "pinning with yourself as the scope works", %{bystander: user, root: post} do
      assert {:ok, _} = Pins.pin(user, post, id(user))
      assert Pins.pinned?(user, post)
    end

    # pinning to a thread and marking an answer (`Bonfire.Social.Answers`) are both this call
    test "a thread's author can pin a reply to the thread", %{
      author: author,
      root: root,
      reply: reply
    } do
      assert {:ok, _} = Pins.pin(author, reply, id(root))
      assert Pins.pinned?(id(root), reply)
    end

    test "someone else in the thread can't pin to it", %{
      bystander: bystander,
      root: root,
      reply: reply
    } do
      assert {:error, _} = Pins.pin(bystander, reply, id(root))
      refute Pins.pinned?(id(root), reply)
    end

    test "someone else can't unpin from the thread", %{
      author: author,
      bystander: bystander,
      root: root,
      reply: reply
    } do
      {:ok, _} = Pins.pin(author, reply, id(root))

      Pins.unpin(bystander, reply, id(root))

      assert Pins.pinned?(id(root), reply)
    end
  end
end
