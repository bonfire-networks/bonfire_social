defmodule Bonfire.Social.Tags do
  use Bonfire.Common.Repo
  use Arrows
  use Bonfire.Common.Utils

  alias Bonfire.Common.Config
  alias Bonfire.Tag.Tags
  alias Bonfire.Social.PostContents
  alias Bonfire.Data.Social.PostContent
  alias Ecto.Changeset

  def cast(changeset, attrs, creator, opts) do
    with true <- module_enabled?(Bonfire.Tag),
         tags when is_list(tags) and length(tags)>0 <-
          (
            e(changeset, :changes, :post_content, :changes, :mentions, []) # tag any mentions that were found in the text and injected into the changeset by PostContents (NOTE: this doesn't necessarly mean they should be included in boundaries or notified)
            ++ e(changeset, :changes, :post_content, :changes, :hashtags, []) # tag any hashtags that were found in the text and injected into the changeset by PostContents
            ++ e(attrs, :tags, [])
          )
          |> filter_empty([])
          |> uniq_by_id()
          |> debug("cast tags")
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

  def maybe_process(creator, text) do
    with true <- is_binary(text) and text !="",
         true <- module_enabled?(Bonfire.Tag),
         {text, mentions, hashtags} <- Bonfire.Tag.TextContent.Process.process(creator, text, "text/markdown") do # TODO: set content-type based on which rich editor is used?
      {:ok, %{text: text, mentions: Keyword.values(mentions), hashtags: Keyword.values(hashtags)}}

    else _ ->
      {:ok, %{text: text, mentions: [], hashtags: []}}
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
