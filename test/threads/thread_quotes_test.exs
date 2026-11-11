defmodule Bonfire.Social.ThreadQuotesTest do
  use Bonfire.Social.DataCase, async: false

  alias Bonfire.Posts
  alias Bonfire.Social.Quotes

  setup do
    alice = fake_user!()
    bob = fake_user!()
    post = publish(alice)
    {:ok, alice: alice, bob: bob, post: post}
  end

  # the quote asks in this person's notifications, with what `experienced_as/3` reads loaded
  defp quote_asks_in_notifications(user) do
    request_verb_id = Bonfire.Boundaries.Verbs.get_id!(:request)

    %{edges: edges} = Bonfire.Social.FeedLoader.feed(:notifications, current_user: user)

    edges
    |> Enum.map(& &1.activity)
    |> Enum.filter(&(&1.verb_id == request_verb_id))
    |> repo().maybe_preload([:edge, object: [:created]])
  end

  # A feed read at this level never gets `:with_request_edge`, which the notifications view adds from its filters, so every ask reads as a follow request there. Covered through the real pages in `bonfire_ui_social/test/views/notifications/quote_approved_notification_test.exs`. Kept here as a comment:
  # test "an approved quote reads as approved in the quoter's Latest and Requests feeds", %{alice: alice, bob: bob, post: quoted} do
  #   post = publish(bob, quotes: [quoted])
  #   assert {:ok, _} = Quotes.accept_quote(post, quoted, current_user: alice)
  #   feed = Bonfire.Social.FeedLoader.feed(:notifications, current_user: bob)
  #   ... experienced_as(activity, id(bob)) == :quote
  # end

  test "pending quotes are absent from counts and pages until approval", %{
    alice: alice,
    bob: bob,
    post: quoted
  } do
    post = publish(bob, quotes: [quoted])
    opts = [current_user: alice]

    assert {:ok, _} = Quotes.requested(post, quoted)
    assert Quotes.count([in_thread: quoted.id], opts) == 0
    assert Quotes.list_paginated([in_thread: quoted.id], opts).edges == []

    # asking tells only the author of what is quoted: the one asking has nothing in their notifications
    assert [_] = quote_asks_in_notifications(alice),
           "control: the author of the quoted post is asked"

    assert [] == quote_asks_in_notifications(bob)

    assert {:ok, _} = Quotes.accept_quote(post, quoted, current_user: alice)

    # and the answer is yes, which tells the one who asked, from their side. The author of the quoted post reads the same ask as before
    assert [activity] = quote_asks_in_notifications(bob)
    assert Bonfire.Social.Activities.experienced_as(activity, id(bob)) == :quote
    assert Bonfire.Social.Activities.experienced_as(activity, id(alice)) == :quote_request

    assert Quotes.count([in_thread: quoted.id], opts) == 1
    assert [quote] = Quotes.list_paginated([in_thread: quoted.id], opts).edges
    assert quote.id == post.id
    assert quote.created.creator.id == bob.id
    assert Ecto.assoc_loaded?(quote.created.creator.profile)
    assert Ecto.assoc_loaded?(quote.created.creator.character)
  end

  for hidden_side <- [:quoting_post, :quoted_post] do
    test "counts and pages exclude a hidden #{hidden_side}", %{alice: alice, bob: bob, post: root} do
      reply =
        publish(alice,
          boundary: if(unquote(hidden_side) == :quoted_post, do: "mentions", else: "public"),
          post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: root.id}
        )

      publish(alice,
        quotes: [reply],
        boundary: if(unquote(hidden_side) == :quoting_post, do: "mentions", else: "public")
      )

      assert Quotes.count([in_thread: root.id], current_user: alice) == 1
      assert Quotes.count([in_thread: root.id], current_user: bob) == 0
      assert Quotes.list_paginated([in_thread: root.id], current_user: bob).edges == []
    end
  end

  test "counts a quote linking to multiple replies once and paginates distinct posts", %{
    alice: alice,
    post: root
  } do
    replies =
      for _ <- 1..2 do
        publish(alice,
          post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}, reply_to_id: root.id}
        )
      end

    first = publish(alice, quotes: replies)
    second = publish(alice, quotes: [root])
    other_root = publish(alice)
    publish(alice, quotes: [other_root])
    opts = [current_user: alice, limit: 1]

    assert Quotes.count([in_thread: root.id], opts) == 2
    page = Quotes.list_paginated([in_thread: root.id], opts)
    assert Enum.map(page.edges, & &1.id) == [second.id]
    assert is_binary(page.page_info.end_cursor)

    next_page =
      Quotes.list_paginated([in_thread: root.id], opts ++ [after: page.page_info.end_cursor])

    assert Enum.map(next_page.edges, & &1.id) == [first.id]
    assert next_page.page_info.end_cursor == nil
  end

  # `check_quote_permission/3` reads the `:request` verb on the quoted post to decide between "ask the author" and "not allowed at all" (`quotes.ex:129`). Asking to quote is available by default, so a public or local post grants `:request` and a stranger gets `:request_needed` rather than a refusal. Both cases are asserted because they are one branch apart: a bug that stops granting `:request` turns every ask into `:not_permitted`, which looks like a deliberate refusal.
  describe "asking to quote a post" do
    test "a stranger may ask to quote a public post", %{bob: bob} do
      alice = fake_user!()
      post = publish(alice, boundary: "public")

      assert {:request_needed, _} = Quotes.check_quote_permission(bob, post)
    end

    test "a stranger may ask to quote a local post", %{bob: bob} do
      alice = fake_user!()
      post = publish(alice, boundary: "local")

      assert {:request_needed, _} = Quotes.check_quote_permission(bob, post)
    end

    test "the author quotes their own post without asking", %{} do
      alice = fake_user!()
      post = publish(alice, boundary: "public")

      assert {:auto_approve, _} = Quotes.check_quote_permission(alice, post),
             "the control: `:request_needed` above is about permission, not about every path returning it"
    end

    # `cannot_read` keeps the `:request` floor so an excluded person may still ask to follow or join, but asking to quote a post means showing it, so it needs `:read` as well.
    test "someone excluded from reading a post may not ask to quote it", %{bob: bob} do
      alice = fake_user!()
      post = publish(alice, boundary: "public", to_circles: %{bob.id => "cannot_read"})

      refute Bonfire.Boundaries.can?(bob, :read, post)

      assert {:not_permitted, _} = Quotes.check_quote_permission(bob, post)
    end

    test "publishing a quote of a post I'm excluded from creates no quote and no request", %{
      bob: bob
    } do
      alice = fake_user!()
      quoted = publish(alice, boundary: "public", to_circles: %{bob.id => "cannot_read"})

      post = publish(bob, quotes: [quoted])

      assert {:error, _} = Quotes.requested(post, quoted)
      assert Bonfire.Social.Tags.list_tags_quote(post) == []
    end
  end

  defp publish(user, opts \\ []) do
    opts =
      Keyword.merge(
        [
          current_user: user,
          boundary: "public",
          post_attrs: %{post_content: %{html_body: Faker.Lorem.sentence()}}
        ],
        opts
      )

    {:ok, post} = Posts.publish(opts)
    post
  end
end
