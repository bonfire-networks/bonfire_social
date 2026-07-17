defmodule Bonfire.Social.TagsTest do
  use Bonfire.Social.DataCase, async: true

  alias Bonfire.Data.Identity.User
  alias Bonfire.Social.Tags

  test "an actor tag is not classified as a quote when its associations are not loaded" do
    actor = %User{}
    tagged_activity = %{tags: [actor]}

    refute Ecto.assoc_loaded?(actor.character)
    assert Tags.tags_quotes_and_hashtags(tagged_activity) == {[], []}
    assert Tags.tags_quote(tagged_activity) == []
  end

  test "a group/topic tag is not classified as a quote when its associations are not loaded" do
    # Posting into a group tags the post with the group; on a freshly live-pushed
    # activity the tag arrives without `:character` preloaded, which used to make the
    # group render as a quoted-post card in the new activity. A real tag carries a
    # populated `type:` (:group/:topic), which routes `object_type/2` differently than
    # a bare struct — so cover both to guard against the group slipping through as `:group`.
    for type <- [nil, :group, :topic] do
      category = %Bonfire.Classify.Category{type: type}
      tagged_activity = %{tags: [category]}

      refute Ecto.assoc_loaded?(category.character)

      assert Tags.tags_quotes_and_hashtags(tagged_activity) == {[], []},
             "category with type=#{inspect(type)} must not be a quote"

      assert Tags.tags_quote(tagged_activity) == [],
             "category with type=#{inspect(type)} must not be a quote"
    end
  end

  test "a group tag as a bare pointer (unfollowed shared category/hashtag table) is not a quote" do
    # This is the form the tag actually takes on a live push, before pointers are followed
    # to concrete structs — the `2AGS…` table is shared by Category and Hashtag. It must not
    # render as a quote card (the reported bug).
    group_pointer = %{table_id: "2AGSCANBECATEG0RY0RHASHTAG"}
    tagged_activity = %{tags: [group_pointer]}

    assert Tags.tags_quotes_and_hashtags(tagged_activity) == {[], []}
    assert Tags.tags_quote(tagged_activity) == []
  end

  test "a genuine quoted post IS still classified as a quote" do
    # Guard against over-correcting: the quote-tag feature must keep working. A post has no
    # `:character`, so it is the real quote target and must land in the quotes bucket.
    post = %Bonfire.Data.Social.Post{}
    tagged_activity = %{tags: [post]}

    # (the quote is returned with `:sensitive`/`:post_content` preloaded, so assert on
    # shape/type rather than struct equality)
    assert {[%Bonfire.Data.Social.Post{}], []} = Tags.tags_quotes_and_hashtags(tagged_activity)
    assert [%Bonfire.Data.Social.Post{}] = Tags.tags_quote(tagged_activity)
  end
end
