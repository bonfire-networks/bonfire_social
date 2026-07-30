defmodule Bonfire.Social.Objects.ReadPreloadsTest do
  @moduledoc """
  A read must return the assocs it was asked to preload.

  `Bonfire.Social.Objects.read/2` requests activity preloads (eg. `:with_post_content`) which the query honours on `activity.object`; `Activities.activity_under_object/1` then merges that enclosed object with the outer `Needle.Pointer`. Since `Needle.Pointer` declares the same mixins (see `config/bonfire_data.exs`) but has them UNLOADED, merging it as a struct precedence discarded the loaded ones — so a caller asking for `:with_post_content` got `%Ecto.Association.NotLoaded{}` and rendered nothing (found while porting markdown export to a type-agnostic read).
  """
  use Bonfire.DataCase, async: true

  import Bonfire.Posts.Fake, only: [fake_post!: 3]

  alias Bonfire.Data.Social.Activity
  alias Bonfire.Data.Social.Post
  alias Bonfire.Data.Social.PostContent
  alias Bonfire.Social.Activities
  alias Bonfire.Social.Objects

  @moduletag :backend

  describe "activity_under_object/1" do
    test "keeps the enclosed object's loaded post_content (no DB)" do
      id = Needle.ULID.generate()
      content = %PostContent{id: id, html_body: "the loaded body"}

      # the shape `Objects.read/2` builds: the outer pointer carries the activity, whose `object` is the (loaded) concrete struct, while the pointer's own mixins are unloaded
      pointer = %Needle.Pointer{
        id: id,
        activity: %Activity{id: id, object: %Post{id: id, post_content: content}}
      }

      merged = Activities.activity_under_object(pointer)

      assert %PostContent{html_body: "the loaded body"} = merged.post_content
      assert %Activity{} = merged.activity
    end
  end

  describe "Needles.get/2 (do_follow!/2)" do
    test "following a pointer keeps a mixin that was already preloaded on it" do
      me = fake_user!()

      post =
        fake_post!(me, "public", %{post_content: %{html_body: "body loaded on the pointer"}})

      assert {:ok, pointer} = Bonfire.Common.Needles.one(id(post), skip_boundary_check: true)
      pointer = Bonfire.Common.Repo.Preload.maybe_preload(pointer, :post_content)

      # precondition: the mixin really is loaded on the pointer before we follow it
      assert %PostContent{} = pointer.post_content

      assert {:ok, followed} = Bonfire.Common.Needles.get(pointer, skip_boundary_check: true)

      assert %Post{} = followed
      assert %PostContent{} = followed.post_content
      assert followed.post_content.html_body =~ "body loaded on the pointer"
    end
  end

  describe "read/2" do
    test "returns the object with the post content it was asked to preload" do
      me = fake_user!()

      post =
        fake_post!(me, "public", %{
          post_content: %{name: "Preloaded title", html_body: "Preloaded body"}
        })

      assert {:ok, read} =
               Objects.read(id(post), current_user: me, preload: [:with_post_content])

      assert %PostContent{} = read.post_content
      assert read.post_content.name == "Preloaded title"
      assert read.post_content.html_body =~ "Preloaded body"
    end
  end
end
