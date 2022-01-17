defmodule Bonfire.Social.Tags do
  alias Bonfire.Common.Utils
  alias Bonfire.Tag.Tags

  def maybe_tag(creator, post, tags, mentions_are_private? \\ true) do
    if Utils.module_enabled?(Bonfire.Tag.Tags), do: Bonfire.Tag.Tags.maybe_tag(creator, post, tags, mentions_are_private?),
    else: {:ok, post}
  end

  def cast(changeset, attrs, creator, mentions, _hashtags, preset) do
    
  end

end
