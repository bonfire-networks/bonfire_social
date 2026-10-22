defmodule Bonfire.Social.GroupPinsTest do
  @moduledoc "Pinning a post to the top of a group, or of a topic in it, is a moderator's call: it takes `:mediate` on the group (a topic's parent group), not the `:pin` that members of an open group also hold."
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Social.Pins
  alias Bonfire.Classify.Categories
  import Bonfire.Classify.Simulate

  setup do
    # these are about permission; federation of group pins is covered in `pins_federation_test.exs`
    Process.put(:federating, false)

    creator = fake_user!(fake_account!())
    moderator = fake_user!(fake_account!())
    member = fake_user!(fake_account!())

    group =
      fake_group!(creator, %{
        membership: "open",
        visibility: "global",
        participation: "group_members"
      })

    {:ok, _} = Categories.join_group(member, id(group))
    {:ok, _} = Categories.add_moderator(creator, group, id(moderator))

    topic = fake_category!(creator, group, %{type: :topic})

    %{
      creator: creator,
      moderator: moderator,
      member: member,
      group: group,
      topic: topic,
      post: fake_post_in_group!(member, group, "<p>in the group</p>"),
      topic_post: fake_post_in_topic!(member, topic, "<p>in the topic</p>")
    }
  end

  test "a member of a members-participation group can't pin to it", %{
    member: member,
    group: group,
    post: post
  } do
    assert Bonfire.Boundaries.can?(member, :pin, group),
           "control: members hold `:pin` through `:contribute`"

    assert {:error, _} = Pins.pin(member, post, id(group))
    refute Pins.pinned?(id(group), post)
  end

  test "a member can't unpin what a moderator pinned", %{
    moderator: moderator,
    member: member,
    group: group,
    post: post
  } do
    {:ok, _} = Pins.pin(moderator, post, id(group))

    assert {:error, _} = Pins.unpin(member, post, id(group))
    assert Pins.pinned?(id(group), post)
  end

  test "a local user of an \"anyone\" group can't pin to it", %{creator: creator} do
    group =
      fake_group!(creator, %{membership: "open", visibility: "global", participation: "anyone"})

    stranger = fake_user!(fake_account!())
    post = fake_post_in_group!(stranger, group, "<p>anyone can post</p>")

    assert {:error, _} = Pins.pin(stranger, post, id(group))
    refute Pins.pinned?(id(group), post)
  end

  test "a moderator can pin and unpin in the group", %{
    moderator: moderator,
    group: group,
    post: post
  } do
    assert {:ok, _} = Pins.pin(moderator, post, id(group))
    assert Pins.pinned?(id(group), post)

    assert {:ok, _} = Pins.unpin(moderator, post, id(group))
    refute Pins.pinned?(id(group), post)
  end

  test "a moderator can pin and unpin in a topic of the group", %{
    moderator: moderator,
    topic: topic,
    topic_post: post
  } do
    assert {:ok, _} = Pins.pin(moderator, post, id(topic))
    assert Pins.pinned?(id(topic), post)

    assert {:ok, _} = Pins.unpin(moderator, post, id(topic))
    refute Pins.pinned?(id(topic), post)
  end

  test "a member can't pin in a topic of the group", %{
    member: member,
    topic: topic,
    topic_post: post
  } do
    assert {:error, _} = Pins.pin(member, post, id(topic))
    refute Pins.pinned?(id(topic), post)
  end

  # a mirrored group's moderators circle is filled from the origin's list (`Categories.sync_remote_moderators/3`), so its moderators may not be members
  test "a moderator who isn't a member can pin in a topic of the group", %{
    group: group,
    topic: topic,
    topic_post: post
  } do
    listed = fake_user!(fake_account!())
    {:ok, circle} = Categories.moderators_circle(group)
    Bonfire.Boundaries.Circles.add_to_circles(listed, circle)

    assert Bonfire.Boundaries.can?(listed, :mediate, group), "control: a moderator"
    refute Categories.member?(listed, group), "control: not a member"

    assert {:ok, _} = Pins.pin(listed, post, id(topic))
    assert Pins.pinned?(id(topic), post)
  end

  # a group post from before the moderators' ACL existed carries only the members circle
  test "a moderator can pin a group post that lacks the moderators' ACL", %{
    moderator: moderator,
    member: member,
    group: group
  } do
    {:ok, members} = Categories.members_circle(group)

    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: member,
        post_attrs: %{post_content: %{html_body: "<p>an older post</p>"}},
        context_id: id(group),
        to_circles: [id(members)],
        boundary: "mentions"
      )

    assert {:ok, _} = Pins.pin(moderator, post, id(group))
    assert Pins.pinned?(id(group), post)
  end

  describe "list_pinned_activities/2" do
    defp pinned_object_ids(%{edges: edges}),
      do: Enum.map(edges, &e(&1, :activity, :object_id, nil))

    test "lists a group's pins as activities, in rank order, at most 3", %{
      moderator: moderator,
      member: member,
      group: group
    } do
      posts =
        for n <- 1..4 do
          post = fake_post_in_group!(member, group, "<p>pin #{n}</p>")
          {:ok, _} = Pins.pin(moderator, post, id(group))
          post
        end

      # the reverse of pin order, so rank (not insertion order) decides
      [first, second, third, _fourth] = Enum.reverse(posts)

      posts
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.each(fn {post, position} -> {:ok, _} = Pins.rank_pin(id(post), group, position) end)

      assert pinned_object_ids(Pins.list_pinned_activities(group, current_user: member)) ==
               [id(first), id(second), id(third)]
    end

    test "leaves out pins the viewer can't read", %{
      moderator: moderator,
      member: member,
      group: group,
      post: post
    } do
      {:ok, hidden} =
        Bonfire.Posts.publish(
          current_user: moderator,
          post_attrs: %{post_content: %{html_body: "<p>for moderators</p>"}},
          boundary: "mentions"
        )

      {:ok, _} = Pins.pin(moderator, post, id(group))
      {:ok, _} = Pins.pin(moderator, hidden, id(group))

      listed = pinned_object_ids(Pins.list_pinned_activities(group, current_user: member))

      assert id(post) in listed
      refute id(hidden) in listed
    end

    test "still fills the limit when the top-ranked pins are hidden from the viewer", %{
      moderator: moderator,
      member: member,
      group: group,
      post: post
    } do
      {:ok, _} = Pins.pin(moderator, post, id(group))

      # five hidden pins ranked ahead of the readable one
      for position <- 0..4 do
        {:ok, hidden} =
          Bonfire.Posts.publish(
            current_user: moderator,
            post_attrs: %{post_content: %{html_body: "<p>hidden #{position}</p>"}},
            boundary: "mentions"
          )

        {:ok, _} = Pins.pin(moderator, hidden, id(group))
        {:ok, _} = Pins.rank_pin(id(hidden), group, position)
      end

      assert pinned_object_ids(Pins.list_pinned_activities(group, current_user: member, limit: 1)) ==
               [id(post)]
    end

    test "only lists that scope's pins", %{
      moderator: moderator,
      group: group,
      topic: topic,
      post: post,
      topic_post: topic_post
    } do
      {:ok, _} = Pins.pin(moderator, post, id(group))
      {:ok, _} = Pins.pin(moderator, topic_post, id(topic))

      assert pinned_object_ids(Pins.list_pinned_activities(group, current_user: moderator)) ==
               [id(post)]

      assert pinned_object_ids(Pins.list_pinned_activities(topic, current_user: moderator)) ==
               [id(topic_post)]
    end
  end

  test "pinning to a group by its id loads the group before federating", %{
    moderator: moderator,
    group: group,
    post: post
  } do
    Process.put(:federating, true)

    assert {:ok, _} = Pins.pin(moderator, post, id(group))
    assert Pins.pinned?(id(group), post)
  end
end
