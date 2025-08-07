defmodule Bonfire.Social.LikesTest do
  # use Bonfire.Social.DataCase, async: true
  use Bonfire.Social.DataCase

  import Bonfire.Files.Simulation

  alias Bonfire.Social.Likes
  alias Bonfire.Posts
  alias Bonfire.Social.FeedActivities

  alias Bonfire.Me.Fake
  alias Bonfire.Files.EmojiUploader

  test "like works" do
    alice = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: alice,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, %{edge: edge}} = Likes.like(alice, post)
    # debug(activity)
    assert edge.subject_id == alice.id
    assert edge.object_id == post.id
  end

  test "can check if I like something" do
    alice = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: alice,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, like} = Likes.like(alice, post)
    assert true == Likes.liked?(alice, post)
  end

  test "can check if I did not like something" do
    alice = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: alice,
               post_attrs: attrs,
               boundary: "public"
             )

    assert false == Likes.liked?(alice, post)
  end

  test "can unlike something" do
    alice = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: alice,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, like} = Likes.like(alice, post)
    Likes.unlike(alice, post)
    assert false == Likes.liked?(alice, post)
  end

  test "can list my likes" do
    alice = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: alice,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, like} = Likes.like(alice, post)
    assert %{edges: [fetched_liked]} = Likes.list_my(current_user: alice)
    # debug(fetched_liked)
    assert fetched_liked.edge.object_id == post.id
  end

  test "can paginate my likes" do
    account = Fake.fake_account!()
    alice = Fake.fake_user!(account)
    bob = Fake.fake_user!(account)

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: bob,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, p1} =
             Posts.publish(
               current_user: bob,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, p2} =
             Posts.publish(
               current_user: bob,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, _like} = Likes.like(alice, post)
    assert {:ok, _like1} = Likes.like(alice, p1)
    assert {:ok, _like2} = Likes.like(alice, p2)

    assert %{edges: [_, _]} = Likes.list_my(current_user: alice, limit: 2)
  end

  test "can list the likers of something" do
    alice = Fake.fake_user!()
    bob = Fake.fake_user!()

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: alice,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, like} = Likes.like(alice, post)
    assert {:ok, like2} = Likes.like(bob, post)
    assert %{edges: fetched_liked} = Likes.list_of(post, alice)
    assert Enum.count(fetched_liked, &(&1.edge.object_id == post.id)) == 2
  end

  test "can list someone else's likes" do
    alice = Fake.fake_user!()
    bob = Fake.fake_user!("bob")

    attrs = %{
      post_content: %{
        summary: "summary",
        html_body: "<p>epic html message</p>"
      }
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: alice,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, like} = Likes.like(bob, post)
    # debug( Likes.list_by(bob, alice))
    assert %{edges: [fetched_liked]} = Likes.list_by(bob, alice)
    assert fetched_liked.edge.object_id == post.id
  end

  test "see a like of something I posted in my notifications" do
    alice = Fake.fake_user!()
    bob = Fake.fake_user!()

    attrs = %{
      post_content: %{html_body: "<p>hey you have an epic html post</p>"}
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: alice,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, like} = Likes.like(bob, post)

    assert %{edges: edges} = FeedActivities.feed(:notifications, current_user: alice)

    # for e <- edges, do: IO.inspect(id: e.id, table_id: e.table_id)
    assert [fetched_like] = edges
    assert fetched_like.activity.object_id == post.id
  end

  test "can react with an emoji (i.e. a short text)" do
    me = fake_user!()

    emoji = "🔥"
    label = "fire"

    attrs = %{
      post_content: %{html_body: "<p>hey you have an epic html post</p>"}
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, like} = Likes.like(me, post, reaction_emoji: {emoji, %{label: label}})

    # %{
    #   extra_info: %{
    #     summary: "🔥",
    #     info: %{label: "fire"}
    #   }
    # } = like

    refute like.edge.table_id == "11KES11KET0BE11KEDY0VKN0WS"

    assert %{edges: [fetched_liked]} = Likes.list_my(current_user: me)
    assert fetched_liked.edge.object_id == post.id

    assert true == Likes.liked?(me, post)
  end

  test "can react with a custom emoji (i.e. a Media)" do
    me = fake_user!()

    label = "test custom emoji"
    shortcode = ":test:"

    {:ok, context} = Bonfire.Files.EmojiUploader.add_emoji(me, icon_file(), label, shortcode)
    me = current_user(context)

    assert %{id: media_id, url: url} =
             Bonfire.Common.Settings.get([:custom_emoji, shortcode], nil, me)

    # assert url =~ path

    attrs = %{
      post_content: %{html_body: "<p>hey you have an epic html post</p>"}
    }

    assert {:ok, post} =
             Posts.publish(
               current_user: me,
               post_attrs: attrs,
               boundary: "public"
             )

    assert {:ok, like} = Likes.like(me, post, reaction_media: media_id)

    assert like.edge.table_id == media_id
  end
end
