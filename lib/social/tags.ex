defmodule Bonfire.Social.Tags do
  alias Bonfire.Common.Utils
  alias Bonfire.Common.Config
  alias Bonfire.Tag.Tags
  alias Bonfire.Tag.TextContent
  use Bonfire.Repo

  def maybe_process(creator, attrs) do
    if Utils.module_enabled?(Bonfire.Tag.Tags), do: TextContent.Process.process(creator, attrs, "text/markdown")
  end

  def maybe_tag(creator, post, tags, mentions_are_private? \\ true) do
    if Utils.module_enabled?(Bonfire.Tag.Tags), do: Bonfire.Tag.Tags.maybe_tag(creator, post, tags, mentions_are_private?),
    else: {:ok, post}
  end

  def cast(changeset, attrs, creator, mentions, _hashtags, preset) do
    # TODO
    changeset
  end

  def indexing_format_tags(obj) do
    if Config.module_enabled?(Bonfire.Tag.Tags) do
      repo().maybe_preload(obj, tags: [:profile])
      |> Map.get(:tags, [])
      |> Enum.map(&Bonfire.Tag.Tags.indexing_object_format_name/1)
    end
  end

end
