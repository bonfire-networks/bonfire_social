defmodule Bonfire.Social.Tags do
  use Bonfire.Repo
  use Arrows
  use Bonfire.Common.Utils

  alias Bonfire.Common.Config
  alias Bonfire.Tag.{Tags, TextContent}
  alias Bonfire.Social.PostContents
  alias Bonfire.Data.Social.PostContent
  alias Ecto.Changeset

  def cast(changeset, attrs, creator, opts) do
    with true <- module_enabled?(Bonfire.Tag),
         tags when is_list(tags) and length(tags)>0 <-
          (
            e(changeset, :changes, :post_content, :changes, :mentions, []) # tag any mentions that were found in the text and injected into the changeset by PostContents (NOTE: this doesn't necessarly mean they should be included in boundaries or notified)
            ++ e(attrs, :tags, [])
          )
          |> filter_empty([])
          |> uniq_by_id()
          |> debug
    do
      changeset
      |> Changeset.cast(%{tagged: tags_preloads(tags, opts)}, [])
      # |> debug("before cast assoc")
      |> Changeset.cast_assoc(:tagged, with: &Bonfire.Tag.Tagged.changeset/2)
    else
      _ -> changeset
    end
    # |> debug("changeset")
  end

  def maybe_process(creator, attrs) do
    with true <- module_enabled?(Bonfire.Tag),
         {text, mentions, hashtags} <- TextContent.Process.process(creator, attrs, "text/markdown") do
      {:ok, %{text: text, mentions: Keyword.values(mentions), hashtags: hashtags}}
    end
  end

  defp tags_preloads(mentions, _preset_or_custom_boundary) do
    preload? = true # preset in ["public", "mentions"] # we want to mention local characters too if using the "local" preset
    mentions
    |> if(preload?, do: repo().maybe_preload(..., [:character]), else: ...)
  end

  def maybe_tag(creator, post, tags, mentions_are_private? \\ true) do
    if module_enabled?(Bonfire.Tag.Tags),
      do: Bonfire.Tag.Tags.maybe_tag(creator, post, tags, mentions_are_private?),
    else: {:ok, post}
  end

  def indexing_format_tags(obj) do
    if Bonfire.Common.Extend.module_enabled?(Bonfire.Tag.Tags) do
      repo().maybe_preload(obj, tags: [:profile])
      |> Map.get(:tags, [])
      |> Enum.map(&Bonfire.Tag.Tags.indexing_object_format_name/1)
    end
  end

end
