defmodule Bonfire.Social.ThreadPlaceholderFillTest do
  @moduledoc """
  A post we know of but couldn't fetch stands in its thread as a placeholder: a plain pointer, soft-deleted like a deleted reply so nothing lists it, with the replies under it pointing at its id. When the post arrives it is created under that same id, so they never move.

  What that rests on: a post can be created under a pointer that already exists (Needle's insert triggers do `on conflict do nothing` on the pointer row), and the pointer then repointed to the post's type and undeleted, with the replies' `Replied` rows untouched.
  """
  use Bonfire.Social.DataCase, async: false
  @moduletag :backend

  import Ecto.Query
  alias Bonfire.Posts
  alias Bonfire.Data.Social.Replied
  alias Needle.Pointer

  test "a post created under a placeholder's id takes its place, and the replies under it stay" do
    alice = fake_user!()

    # the placeholder: a plain pointer, of the generic type since the real one isn't known, soft-deleted
    {:ok, placeholder} =
      Pointer.create(Needle.UID.generate(Pointer), Bonfire.Data.Social.APActivity)
      |> repo().insert()

    from(p in Pointer, where: p.id == ^placeholder.id)
    |> repo().update_all(set: [deleted_at: DateTime.utc_now()])

    # a reply threaded under it
    {:ok, reply} =
      Posts.publish(
        current_user: alice,
        boundary: "public",
        post_attrs: %{post_content: %{html_body: "<p>a reply</p>"}}
      )

    from(r in Replied, where: r.id == ^reply.id)
    |> repo().update_all(
      set: [reply_to_id: placeholder.id, thread_id: placeholder.id, path: [placeholder.id]]
    )

    # the post arrives, created under the placeholder's id
    assert {:ok, %{id: post_id}} =
             Posts.publish(
               current_user: alice,
               boundary: "public",
               post_id: placeholder.id,
               post_attrs: %{post_content: %{html_body: "<p>the parent</p>"}}
             )

    assert post_id == placeholder.id

    pointer = repo().get!(Pointer, placeholder.id)

    pointer
    |> Pointer.repoint(Bonfire.Data.Social.Post)
    |> Ecto.Changeset.change(deleted_at: nil)
    |> repo().update!()

    assert {:ok, %Bonfire.Data.Social.Post{}} =
             Bonfire.Common.Needles.get(placeholder.id, skip_boundary_check: true)

    assert Posts.read(placeholder.id, current_user: alice)
           |> elem(1)
           |> repo().maybe_preload(:post_content)
           |> e(:post_content, :html_body, nil) =~ "the parent"

    replied = repo().get!(Replied, reply.id)

    assert {replied.reply_to_id, replied.thread_id, replied.path} ==
             {placeholder.id, placeholder.id, [placeholder.id]},
           "the reply never moved"
  end
end
