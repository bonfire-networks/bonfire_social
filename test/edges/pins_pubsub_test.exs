defmodule Bonfire.Social.PinsPubSubTest do
  @moduledoc "Every pin change goes out on its scope's topic (`Pins.pins_topic/1`), whoever made it (the UI, another tab, an API client, federation), so the pages showing that scope's pins can refresh."
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.Pins
  alias Bonfire.Classify.Categories
  import Bonfire.Classify.Simulate

  setup do
    Process.put(:federating, false)

    creator = fake_user!(fake_account!())
    moderator = fake_user!(fake_account!())

    group =
      fake_group!(creator, %{
        membership: "open",
        visibility: "global",
        participation: "group_members"
      })

    {:ok, _} = Categories.add_moderator(creator, group, id(moderator))

    %{
      moderator: moderator,
      group: group,
      post: fake_post_in_group!(creator, group, "<p>in the group</p>")
    }
  end

  defp subscribe(scope),
    do: Phoenix.PubSub.subscribe(Bonfire.Common.PubSub, Pins.pins_topic(scope))

  test "pinning to a group tells whoever shows that group's pins", ctx do
    subscribe(ctx.group)
    {group_id, post_id} = {id(ctx.group), id(ctx.post)}

    {:ok, _} = Pins.pin(ctx.moderator, ctx.post, group_id)

    assert_receive {{Bonfire.Social.Pins.LiveHandler, :pins_changed},
                    %{scope_id: ^group_id, object_id: ^post_id, kind: :post}}
  end

  test "so does unpinning from it", ctx do
    {group_id, post_id} = {id(ctx.group), id(ctx.post)}
    {:ok, _} = Pins.pin(ctx.moderator, ctx.post, group_id)
    subscribe(ctx.group)

    Pins.unpin(ctx.moderator, post_id, group_id)

    assert_receive {{Bonfire.Social.Pins.LiveHandler, :pins_changed},
                    %{scope_id: ^group_id, object_id: ^post_id, kind: :post}}
  end

  test "a refused pin tells nobody", ctx do
    outsider = fake_user!(fake_account!())
    subscribe(ctx.group)

    assert {:error, _} = Pins.pin(outsider, ctx.post, id(ctx.group))

    refute_receive {{Bonfire.Social.Pins.LiveHandler, :pins_changed}, _}
  end

  test "spotlight pins go to the instance's topic", ctx do
    admin = fake_admin!(fake_account!())
    on_exit(fn -> Pins.list_spotlight_activities(cache: :reset) end)
    subscribe(:instance)
    {instance_id, post_id} = {Pins.instance_scope_id(), id(ctx.post)}

    {:ok, _} = Pins.pin(admin, ctx.post, :instance)

    assert_receive {{Bonfire.Social.Pins.LiveHandler, :pins_changed},
                    %{scope_id: ^instance_id, object_id: ^post_id, kind: :post}}
  end

  # the groups sidebar only cares about groups, so it can skip post pins
  test "pinning a group to one's sidebar goes to one's own topic, marked as a group", ctx do
    user = fake_user!(fake_account!())
    subscribe(user)
    {user_id, group_id} = {id(user), id(ctx.group)}

    {:ok, _} = Pins.pin(user, ctx.group)

    assert_receive {{Bonfire.Social.Pins.LiveHandler, :pins_changed},
                    %{scope_id: ^user_id, object_id: ^group_id, kind: :group}}
  end

  # `rank_pin` takes only the item's id, so it can't say whether it moved a group or a post
  test "reordering the instance's pins goes to its topic, without saying what moved", ctx do
    admin = fake_admin!(fake_account!())
    on_exit(fn -> Pins.list_spotlight_activities(cache: :reset) end)
    {:ok, _} = Pins.pin(admin, ctx.group, :instance)
    subscribe(:instance)
    {instance_id, group_id} = {Pins.instance_scope_id(), id(ctx.group)}

    {:ok, _} = Pins.rank_pin(group_id, :instance, 0)

    assert_receive {{Bonfire.Social.Pins.LiveHandler, :pins_changed},
                    %{scope_id: ^instance_id, object_id: ^group_id, kind: :unknown}}
  end
end
