defmodule Bonfire.Social.Objects.ActivityPreloadsTest do
  @moduledoc """
  `activity_preloads/3` must tolerate objects that legitimately carry no activity.

  Search hands `Bonfire.Social.Activities.activity_preloads/3` a heterogeneous list: user/character hits are deliberately returned unwrapped by `Bonfire.Search.prepare_hits/3` (they have no activity), while post hits are wrapped in an `Activity`. Preloading the (absent) activity on the former sets it to `nil`, and `maybe_preload_quote_tag_children/4` then walked `[Access.key(:activity, []), Access.key(:tags, [])]` over it — `Access.key/2`'s default only covers a *missing* key, not an explicit `nil`, so `Map.get(nil, :tags, [])` raised `BadMapError` and every `@` mention autocomplete request 500'd.
  """
  use Bonfire.Social.DataCase, async: true

  import Bonfire.Posts.Fake, only: [fake_post!: 3]

  alias Bonfire.Data.Social.Activity
  alias Bonfire.Social.Activities

  describe "activity_preloads/3 with :quote_tags" do
    test "a hit with no activity (eg. a user) is returned untouched, not crashed on" do
      user = fake_user!()
      [user_hit] = Bonfire.Boundaries.load_pointers([id(user)], skip_boundary_check: true)

      # precondition: this is the shape search produces — a bare pointer whose activity is not loaded
      assert %Needle.Pointer{} = user_hit
      refute Ecto.assoc_loaded?(user_hit.activity)

      assert [preloaded] = Activities.activity_preloads([user_hit], [:quote_tags], [])

      assert id(preloaded) == id(user)
    end

    test "a mixed list gives each activity hit its own tag children and skips the activity-less ones" do
      me = fake_user!()
      mentioned_a = fake_user!()
      mentioned_b = fake_user!()
      user = fake_user!()

      post_a = mention_post!(me, mentioned_a)
      post_b = mention_post!(me, mentioned_b)

      [user_hit] = Bonfire.Boundaries.load_pointers([id(user)], skip_boundary_check: true)

      hit_a = search_hit(post_a)
      hit_b = search_hit(post_b)

      # precondition: the mentions really were tagged, so there is something for :quote_tags to load
      assert [_ | _] = repo().preload(hit_a.activity, :tags).tags
      assert [_ | _] = repo().preload(hit_b.activity, :tags).tags

      assert [preloaded_user, preloaded_a, preloaded_b] =
               Activities.activity_preloads([user_hit, hit_a, hit_b], [:quote_tags], [])

      assert id(preloaded_user) == id(user)

      # each hit keeps ITS OWN tags (the tag children are loaded in one batched pass for the whole
      # list, so they have to be matched back up by id), with their schema-specific children loaded
      assert [tag_a] = preloaded_a.activity.tags
      assert [tag_b] = preloaded_b.activity.tags
      assert id(tag_a) == id(mentioned_a)
      assert id(tag_b) == id(mentioned_b)
      assert %Bonfire.Data.Identity.Character{} = tag_a.character
      assert %Bonfire.Data.Identity.Character{} = tag_b.character
    end
  end

  defp mention_post!(author, mentioned) do
    fake_post!(author, "public", %{
      post_content: %{html_body: "hey @#{mentioned.character.username}"}
    })
  end

  # the shape `Bonfire.Search.prepare_hits/3` builds for a non-user hit (`object_id` matters:
  # Activity's `tags` join is keyed on it, see `object_tags` in config/bonfire_data.exs)
  defp search_hit(post) do
    %Needle.Pointer{
      id: id(post),
      activity: %Activity{id: id(post), object_id: id(post), object: post}
    }
  end
end
