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
    # the object to have been federated into an ap_object row yet (deliberate lazy preload:
    # a freshly-published post hasn't preloaded its locality assocs)
    {post, Bonfire.Common.URIs.canonical_url(post, preload_if_needed: true)}
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

  # an incoming `Add` is pinned onto the owner of the collection it targets, not onto whoever sent it
  test "an incoming Add to the sender's own featured pins the object for them" do
    user = fake_user!(fake_account!())
    {post, _ap} = publish_post(user, "<p>feature me</p>")

    Pins.ap_receive_activity(
      user,
      %{
        data: %{
          "type" => "Add",
          "target" => ActivityPub.Utils.collection_ap_id("featured", user.id)
        }
      },
      %{pointer_id: post.id, data: %{"type" => "Note"}}
    )

    assert Pins.pinned?(user, post)
  end

  test "an incoming Add to someone else's featured isn't pinned onto the sender, nor onto them" do
    sender = fake_user!(fake_account!())
    owner = fake_user!(fake_account!())
    {post, _ap} = publish_post(sender, "<p>not yours to feature</p>")

    Pins.ap_receive_activity(
      sender,
      %{
        data: %{
          "type" => "Add",
          "target" => ActivityPub.Utils.collection_ap_id("featured", owner.id)
        }
      },
      %{pointer_id: post.id, data: %{"type" => "Note"}}
    )

    refute Pins.pinned?(sender, post)
    refute Pins.pinned?(owner, post)
  end

  describe "pins to the top of a group" do
    setup do
      creator = fake_user!(fake_account!())
      moderator = fake_user!(fake_account!())

      group =
        Bonfire.Classify.Simulate.fake_group!(creator, %{membership: "open", visibility: "global"})

      {:ok, _} = Bonfire.Classify.Categories.add_moderator(creator, group, id(moderator))
      post = Bonfire.Classify.Simulate.fake_post_in_group!(moderator, group, "<p>featured</p>")

      {:ok, %{ap_id: moderator_ap_id}} = ActivityPub.Actor.get_cached(pointer: moderator)
      {:ok, %{ap_id: group_ap_id}} = ActivityPub.Actor.get_cached(pointer: group)

      %{
        moderator: moderator,
        group: group,
        post: post,
        moderator_ap_id: moderator_ap_id,
        group_ap_id: group_ap_id,
        target: ActivityPub.Utils.collection_ap_id("featured", group.id)
      }
    end

    defp sent(type, target) do
      repo().all(
        Ecto.Query.from(o in ActivityPub.Object,
          where:
            fragment("?->>'type' = ?", o.data, ^type) and
              fragment("?->>'target' = ?", o.data, ^target)
        )
      )
    end

    defp announced_by(actor_ap_id, activity_ap_id) do
      repo().all(
        Ecto.Query.from(o in ActivityPub.Object,
          where:
            fragment("?->>'type' = 'Announce'", o.data) and
              fragment("?->>'actor' = ?", o.data, ^actor_ap_id)
        )
      )
      |> Enum.filter(
        &(&1.data["object"] == activity_ap_id or e(&1.data, "object", "id", nil) == activity_ap_id)
      )
    end

    # as Lemmy sends it (`add_featured_post.json`): the moderator adds to the community's featured, cc'd to the community, which announces it
    test "a pin sends an Add from the moderator to the group's featured, which the group announces",
         ctx do
      {:ok, _} = Pins.pin(ctx.moderator, ctx.post, id(ctx.group))

      assert [add] = sent("Add", ctx.target)
      assert add.data["actor"] == ctx.moderator_ap_id
      assert ctx.group_ap_id in List.wrap(add.data["cc"])

      assert [_] = announced_by(ctx.group_ap_id, add.data["id"])
    end

    test "the unpin sends a Remove from the same moderator to the same collection", ctx do
      {:ok, _} = Pins.pin(ctx.moderator, ctx.post, id(ctx.group))
      Pins.unpin(ctx.moderator, ctx.post, id(ctx.group))

      assert [remove] = sent("Remove", ctx.target)
      assert remove.data["actor"] == ctx.moderator_ap_id

      assert ActivityPub.Utils.collection_ap_id("featured", ctx.moderator.id)
             |> then(&sent("Remove", &1)) == [],
             "not from the moderator's own featured"
    end

    # `parse_collection_ap_id/1` ignores the host, so a look-alike of our host would otherwise name our group
    test "an incoming Add to a featured on a look-alike host isn't taken as our group's", ctx do
      base = Bonfire.Common.URIs.base_url()
      lookalike = String.replace_prefix(ctx.target, base, base <> ".evil.example")
      assert lookalike != ctx.target, "control: the target is on our host"

      Pins.ap_receive_activity(
        ctx.moderator,
        %{data: %{"type" => "Add", "target" => lookalike}},
        %{pointer_id: ctx.post.id, data: %{"type" => "Note"}}
      )

      refute Pins.pinned?(id(ctx.group), ctx.post)
    end

    test "the group's featured collection serves its pins", ctx do
      {:ok, _} = Pins.pin(ctx.moderator, ctx.post, id(ctx.group))

      assert Pins.collection_items(%{data: %{"id" => ctx.target}}) == [id(ctx.post)]
    end
  end
end
