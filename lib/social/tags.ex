defmodule Bonfire.Social.Tags do
  alias Bonfire.Common.Utils

  def maybe_tag(creator, post, tags) do
    if Utils.module_enabled?(Bonfire.Tag.Tags), do: Bonfire.Tag.Tags.maybe_tag(creator, post, tags), #|> IO.inspect
    else: {:ok, post}
  end

end
