defmodule Bonfire.Social.FeedsFilterReplyToCreatorsTest do
  @moduledoc """
  A feed can pick replies by whose posts they sit below: `reply_to_creators` keeps a reply when one of the given people wrote any post above it in its thread, and `exclude_reply_to_creators` keeps the rest.

  This is what tells "a reply to me" from a reply that reached me through a bell on someone else's thread. The Replies chip uses it with `:me`, the way the Mentions chip uses `tags: [:me]`. `creators` can't answer it, since it is who wrote the reply.

  "Above it" is the reply's whole ancestry (`Replied.path`): a reply to my post, a reply in my thread to someone else's comment, and a reply to a grandchild of my comment all count as replies to me.
  """
  use Bonfire.Social.DataCase, async: true
  @moduletag :backend

  alias Bonfire.Social.FeedLoader
  alias Bonfire.Me.Fake
  import Bonfire.Posts.Fake

  setup do
    Process.put([:bonfire, :default_pagination_limit], 20)

    me = Fake.fake_user!()
    them = Fake.fake_user!()
    replier = Fake.fake_user!()

    my_post = fake_post!(me, "public", %{post_content: %{html_body: "my own thread"}})
    their_post = fake_post!(them, "public", %{post_content: %{html_body: "their thread"}})

    reply_to_me =
      fake_post!(replier, "public", %{
        post_content: %{html_body: "an answer to me"},
        reply_to_id: id(my_post)
      })

    # answers the replier's comment, in the thread I started
    reply_in_my_thread =
      fake_post!(them, "public", %{
        post_content: %{html_body: "an answer to a comment in my thread"},
        reply_to_id: id(reply_to_me)
      })

    # what a bell on their thread brings me: nothing of mine is answered
    reply_elsewhere =
      fake_post!(replier, "public", %{
        post_content: %{html_body: "an answer in their thread"},
        reply_to_id: id(their_post)
      })

    # further down their thread, below a comment of mine: a reply to a reply to my reply
    my_reply =
      fake_post!(me, "public", %{
        post_content: %{html_body: "my comment in their thread"},
        reply_to_id: id(their_post)
      })

    child =
      fake_post!(them, "public", %{
        post_content: %{html_body: "an answer to my comment"},
        reply_to_id: id(my_reply)
      })

    grandchild =
      fake_post!(replier, "public", %{
        post_content: %{html_body: "an answer below my comment"},
        reply_to_id: id(child)
      })

    {:ok,
     me: me,
     reply_to_me: reply_to_me,
     reply_in_my_thread: reply_in_my_thread,
     reply_elsewhere: reply_elsewhere,
     grandchild: grandchild}
  end

  defp replies(me, filters) do
    FeedLoader.feed(
      :custom,
      Map.merge(%{activity_types: [:reply], show_objects_only_once: false}, filters),
      current_user: me
    )
  end

  defp in?(feed, object, me), do: FeedLoader.feed_contains?(feed, object, current_user: me)

  test "without the filter, all the replies are there, so the filter is what picks", %{
    me: me,
    reply_to_me: reply_to_me,
    reply_in_my_thread: reply_in_my_thread,
    reply_elsewhere: reply_elsewhere,
    grandchild: grandchild
  } do
    feed = replies(me, %{})

    assert in?(feed, reply_to_me, me)
    assert in?(feed, reply_in_my_thread, me)
    assert in?(feed, reply_elsewhere, me)
    assert in?(feed, grandchild, me)
  end

  test "reply_to_creators keeps any reply with a post of mine above it in the thread", %{
    me: me,
    reply_to_me: reply_to_me,
    reply_in_my_thread: reply_in_my_thread,
    reply_elsewhere: reply_elsewhere,
    grandchild: grandchild
  } do
    feed = replies(me, %{reply_to_creators: [id(me)]})

    assert in?(feed, reply_to_me, me)
    assert in?(feed, reply_in_my_thread, me)
    assert in?(feed, grandchild, me)
    refute in?(feed, reply_elsewhere, me)
  end

  test "exclude_reply_to_creators keeps the rest", %{
    me: me,
    reply_to_me: reply_to_me,
    reply_in_my_thread: reply_in_my_thread,
    reply_elsewhere: reply_elsewhere,
    grandchild: grandchild
  } do
    feed = replies(me, %{exclude_reply_to_creators: [id(me)]})

    assert in?(feed, reply_elsewhere, me)
    refute in?(feed, reply_to_me, me)
    refute in?(feed, reply_in_my_thread, me)
    refute in?(feed, grandchild, me)
  end

  test "both filters are ones a feed accepts" do
    assert :reply_to_creators in Bonfire.Social.FeedFilters.supported_filters()
    assert :exclude_reply_to_creators in Bonfire.Social.FeedFilters.supported_filters()
  end
end
