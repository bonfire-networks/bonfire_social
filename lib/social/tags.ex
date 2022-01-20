defmodule Bonfire.Social.Tags do
  use Bonfire.Repo
  use Arrows

  alias Bonfire.Common.Utils
  alias Bonfire.Common.Config
  alias Bonfire.Tag.{Tags, TextContent}
  alias Bonfire.Social.PostContents
  alias Bonfire.Data.Social.PostContent
  alias Ecto.Changeset

  def cast(changeset, attrs, creator, preset) do
    with true <- Utils.module_enabled?(Bonfire.Tag.Tags),
         mentions when not is_nil(mentions) <- Utils.e(changeset, :changes, :post_content, :changes, :mentions, nil) do
      changeset
      |> Changeset.cast(%{tags: tags_preloads(mentions, preset)} |> IO.inspect, [])
      |> Changeset.cast_assoc(:tags, with: &Bonfire.Tag.Tagged.changeset/2)
    else
      _ -> changeset
    end
    |> IO.inspect(label: "Social.Tags.cast: changeset")
    # TODO: cast the tags themselves
    #
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
