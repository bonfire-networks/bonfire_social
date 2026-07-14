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
end
