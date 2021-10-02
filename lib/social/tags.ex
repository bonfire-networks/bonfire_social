defmodule Bonfire.Social.Tags do
  alias Bonfire.Common.Utils

  def maybe_tag(creator, post, tags, mentions_are_private? \\ true) do
    if Utils.module_enabled?(Bonfire.Tag.Tags), do: Bonfire.Tag.Tags.maybe_tag(creator, post, tags, mentions_are_private?),
    else: {:ok, post}
  end

end
