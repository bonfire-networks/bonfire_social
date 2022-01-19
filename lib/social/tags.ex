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
         {text, mentions, hashtags} <- TextContent.Process.process(creator, attrs, "text/markdown") do
      %{mentions: preload_mentions(mentions, preset),
        hashtags: Keyword.values(hashtags)}
      |> Map.merge(PostContents.prepare_content(attrs, text))
      # |> IO.inspect(label: "Social.Tags.cast:attrs")
      |> Changeset.cast(changeset, %{post_content: ...}, [])
    else
      _ -> Changeset.cast(changeset, %{post_content: PostContents.prepare_content(attrs)}, [])
    end
    |> Changeset.cast_assoc(:post_content, required: true, with: &PostContents.changeset/2)
    # |> IO.inspect(label: "changeset")
    # TODO: cast the tags themselves
  end

  defp preload_mentions(mentions, preset) do
    preload? = true # preset in ["public", "mentions"] # we want to metion local characters too if using the "local" preset
    mentions
    |> Keyword.values()
    |> if(preload?, do: repo().maybe_preload(..., [character: :inbox]), else: ...)
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
