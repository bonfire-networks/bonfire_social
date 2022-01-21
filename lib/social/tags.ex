defmodule Bonfire.Social.Tags do
  use Bonfire.Repo
  use Arrows
  use Bonfire.Common.Utils

  alias Bonfire.Common.Config
  alias Bonfire.Tag.{Tags, TextContent}
  alias Bonfire.Social.PostContents
  alias Bonfire.Data.Social.PostContent
  alias Ecto.Changeset

  def cast(changeset, attrs, creator, preset, extra_tags \\ []) do
    with true <- Utils.module_enabled?(Bonfire.Tag.Tags),
         tags when is_list(tags) and length(tags)>0 <-
          Utils.e(changeset, :changes, :post_content, :changes, :mentions, []) # use any mentions that were found in the text and injected into the changeset by PostContents
          ++ Utils.e(attrs, :tags, [])
          ++ extra_tags
    do
      changeset
      |> Changeset.cast(%{tagged: tags_preloads(tags, preset)}, [])
      # |> Utils.debug("before cast assoc")
      |> Changeset.cast_assoc(:tagged, with: &Bonfire.Tag.Tagged.changeset/2)
    else
      _ -> changeset
    end
    # |> Utils.debug("changeset")
  end

  def maybe_process(creator, attrs) do
    with true <- Utils.module_enabled?(Bonfire.Tag.Tags),
         {text, mentions, hashtags} <- TextContent.Process.process(creator, attrs, "text/markdown") do
      {:ok, %{text: text, mentions: mentions, hashtags: hashtags}}
    end
  end

  defp tags_preloads(mentions, preset) do
    preload? = true # preset in ["public", "mentions"] # we want to metion local characters too if using the "local" preset
    mentions
    |> Keyword.values()
    |> if(preload?, do: repo().maybe_preload(..., [character: :inbox]) |> repo().maybe_preload(:inbox), else: ...)
  end

  def maybe_tag(creator, post, tags, mentions_are_private? \\ true) do
    if Utils.module_enabled?(Bonfire.Tag.Tags),
      do: Bonfire.Tag.Tags.maybe_tag(creator, post, tags, mentions_are_private?),
    else: {:ok, post}
  end

  def indexing_format_tags(obj) do
    if Config.module_enabled?(Bonfire.Tag.Tags) do
      repo().maybe_preload(obj, tags: [:profile])
      |> Map.get(:tags, [])
      |> Enum.map(&Bonfire.Tag.Tags.indexing_object_format_name/1)
    end
  end

end
