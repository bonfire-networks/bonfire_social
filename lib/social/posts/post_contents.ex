defmodule Bonfire.Social.PostContents do
  use Arrows

  alias Bonfire.Data.Social.PostContent
  alias Bonfire.Common.Extend
  alias Bonfire.Common.Utils
  alias Ecto.Changeset

  def cast(changeset, attrs, creator, _preset_or_custom_boundary) do
    # TODO: process tags within the prepare_text function instead (so tags can be used in all three fields at once)
    with {:ok, tags} <- Bonfire.Social.Tags.maybe_process(creator, attrs) do
      tags
      |> Map.merge(prepare_content(attrs, Utils.e(tags, :text, nil)))
      # |> debug(label: "Social.PostContents.cast: attrs")
      |> Changeset.cast(changeset, %{post_content: ...}, [])
    else
      _ -> Changeset.cast(changeset, %{post_content: prepare_content(attrs)}, [])
    end
    |> Changeset.cast_assoc(:post_content, required: true, with: &changeset/2)
    # |> debug(label: "Social.PostContents: changeset")
  end

  def prepare_content(attrs, text \\ nil)
  def prepare_content(%{post_content: %{} = attrs}, text), do: prepare_content(attrs, text)
  def prepare_content(%{post: %{} = attrs}, text), do: prepare_content(attrs, text)
  def prepare_content(attrs, text) when is_binary(text) and bit_size(text) > 0 do
    # use seperate text param if provided directly
    Map.merge(attrs, %{
      html_body: prepare_text(text),
      name: prepare_text(Map.get(attrs, :name)),
      summary: prepare_text(Map.get(attrs, :summary))
    })
  end
  def prepare_content(%{summary: summary, html_body: body} = attrs, _) when (not is_binary(body) or body=="") and not (is_nil(summary) or summary=="") do
    # use summary as body if no body entered
    Map.merge(attrs, %{
      html_body: prepare_text(summary),
      summary: nil,
      name: prepare_text(Map.get(attrs, :name))
    })
  end
  def prepare_content(%{name: name, html_body: body} = attrs, _) when (not is_binary(body) or body=="") and not (is_nil(name) or name=="") do
    # use title as body if no body entered
    Map.merge(attrs, %{
      html_body: prepare_text(name),
      name: nil,
      summary: prepare_text(Map.get(attrs, :summary))
    })
  end
  def prepare_content(%{} = attrs, _) do
    Map.merge(attrs, %{
      html_body: prepare_text(Map.get(attrs, :html_body)),
      name: prepare_text(Map.get(attrs, :name)),
      summary: prepare_text(Map.get(attrs, :summary))
    })
  end
  def prepare_content(attrs, _), do: attrs

  def prepare_text(text) when is_binary(text) and text !="" do
    if Extend.module_enabled?(Emote) do
      text
      |> Utils.markdown()
      |> Emote.convert_text()
    else
      text
      |> Utils.markdown()
    end
  end
  def prepare_text(other), do: other


  def indexing_object_format(%{post_content: obj}), do: indexing_object_format(obj)
  def indexing_object_format(%PostContent{id: _} = obj) do

    # obj = Bonfire.Repo.maybe_preload(obj, [:icon, :image])

    # icon = Bonfire.Files.IconUploader.remote_url(obj.icon)
    # image = Bonfire.Files.ImageUploader.remote_url(obj.image)

    %{
      "index_type" => "Bonfire.Data.Social.PostContent",
      "name" => obj.name,
      "summary" => obj.summary,
      "html_body" => obj.html_body,
      # "icon" => %{"url"=> icon},
      # "image" => %{"url"=> image},
   }
  end

  def indexing_object_format(_), do: nil

  def changeset(%PostContent{} = cs \\ %PostContent{}, attrs) do
    PostContent.changeset(cs, attrs)
    |> Changeset.cast(attrs, [:hashtags, :mentions])
  end

end
