defmodule Bonfire.Social.PinsFederationTest do
  @moduledoc "Federating a user's pins as their Mastodon-compatible `featured` collection, via the generic AP collection substrate (adapter `collection_items`/`collection_total` + `ActivityPub.add`/`remove`)."
  use Bonfire.Social.DataCase

  alias Bonfire.Social.Pins
  alias Bonfire.Posts
  alias ActivityPub.GenericCollectionStore, as: Store
  alias ActivityPub.Federator.Adapter

  defp featured_collection(user) do
    {:ok, actor} = ActivityPub.Actor.get_cached(pointer: user.id)

    {:ok, collection} =
      Store.get_or_create_collection("featured", user.id, actor.ap_id, ordered: true)

    {actor, collection}
  end

  defp publish_post(user, body) do
    {:ok, post} =
      Posts.publish(
        current_user: user,
        post_attrs: %{post_content: %{html_body: body}},
        boundary: "public"
      )

    # canonical_url is the object's ap_id (matches what Pins/adapter serve), and doesn't require
    # the object to have been federated into an ap_object row yet
    {post, Bonfire.Common.URIs.canonical_url(post)}
  end

  test "the featured collection serves the user's pinned objects as an OrderedCollection" do
    user = fake_user!(fake_account!())
    {post1, ap1} = publish_post(user, "<p>one</p>")
    {post2, ap2} = publish_post(user, "<p>two</p>")
    {:ok, _} = Pins.pin(user, post1)
    {:ok, _} = Pins.pin(user, post2)

    {_actor, collection} = featured_collection(user)
    json = ActivityPub.Web.ObjectView.render("collection.json", %{collection: collection})

    assert json["type"] == "OrderedCollection"
    assert json["totalItems"] == 2
    items = json["first"]["orderedItems"]
    assert ap1 in items
    assert ap2 in items
  end

  test "collection_items dispatches featured to Pins, defers keyPackages to the store" do
    user = fake_user!(fake_account!())
    {post, ap} = publish_post(user, "<p>pinned</p>")
    {:ok, _} = Pins.pin(user, post)

    {actor, featured} = featured_collection(user)
    assert ap in Adapter.collection_items(featured)
    assert Adapter.collection_total(featured) == 1

    # keyPackages is store-backed: Pins returns nil → lib store fallback (empty here)
    {:ok, kp} = Store.get_or_create_collection("keyPackages", user.id, actor.ap_id)
    assert Adapter.collection_items(kp) == []
    assert Adapter.collection_total(kp) == 0
  end

  test "pinning federates an Add to the featured collection (unpin → Remove)" do
    user = fake_user!(fake_account!())
    {post, ap} = publish_post(user, "<p>pin me</p>")
    {:ok, pin} = Pins.pin(user, post)

    target = ActivityPub.Utils.collection_ap_id("featured", user.id)

    # Pins.pin already federates (via maybe_federate_and_gift_wrap_activity → ap_publish_activity),
    # creating the Add anchored to the pin's pointer
    assert {:ok, add} = ActivityPub.Object.get_cached(pointer: uid(pin))
    assert add.data["type"] == "Add"
    assert add.data["object"] == ap
    assert add.data["target"] == target

    # unpin federates a Remove (no pin pointer, so it won't collide with the Add's ap_object)
    assert Pins.unpin(user, post)

    remove =
      repo().one(
        Ecto.Query.from(o in ActivityPub.Object,
          where:
            fragment("?->>'type' = ?", o.data, "Remove") and
              fragment("?->>'target' = ?", o.data, ^target),
          order_by: [desc: o.inserted_at],
          limit: 1
        )
      )

    assert remove.data["object"] == ap
  end

  test "instance-wide pins federate as (and serve from) the service actor's featured collection" do
    admin = fake_admin!(fake_account!())
    {post, ap} = publish_post(admin, "<p>instance pinned</p>")
    {:ok, _} = Pins.pin(admin, post, :instance)

    {:ok, service} = ActivityPub.Utils.service_actor()

    # the service/Application actor's featured collection maps to instance-wide pins
    collection = %ActivityPub.Object{
      data: %{
        "id" => ActivityPub.Utils.collection_ap_id("featured", service.id),
        "type" => "OrderedCollection",
        "attributedTo" => service.ap_id
      }
    }

    json = ActivityPub.Web.ObjectView.render("collection.json", %{collection: collection})
    assert ap in json["first"]["orderedItems"]

    # the instance pin is NOT in the admin's *personal* featured (different subject)
    assert Pins.collection_items(%{
             data: %{"id" => ActivityPub.Utils.collection_ap_id("featured", admin.id)}
           }) == []
  end

  test "incoming Add to a featured collection pins the object (ap_receive_activity)" do
    user = fake_user!(fake_account!())
    {post, _ap} = publish_post(user, "<p>feature me</p>")

    Pins.ap_receive_activity(
      user,
      %{data: %{"type" => "Add"}},
      %{pointer_id: post.id, data: %{"type" => "Note"}}
    )

    assert Pins.pinned?(user, post)
  end
end
