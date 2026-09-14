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

    assert {:ok, _} = Quotes.accept_quote(post, quoted, current_user: alice)

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
