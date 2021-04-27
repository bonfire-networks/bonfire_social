defmodule Bonfire.Social.PostContents do
  alias Bonfire.Data.Social.PostContent

  def prepare_content(attrs, text \\ nil)
  def prepare_content(%{post_content: %{} = attrs}, text), do: prepare_content(attrs, text)
  def prepare_content(%{post: %{} = attrs}, text), do: prepare_content(attrs, text)
  def prepare_content(attrs, text) when is_binary(text) and bit_size(text) > 0 do
    # use text overide if provided
    Map.merge(attrs, %{html_body: text})
  end
  def prepare_content(%{name: name, html_body: body} = attrs, _) when is_nil(body) or body=="" do
    # use title as body if no body entered
    Map.merge(attrs, %{html_body: name, name: ""})
  end
  def prepare_content(attrs, _), do: attrs


  def indexing_object_format(%{post_content: obj}), do: indexing_object_format(obj)
  def indexing_object_format(%PostContent{id: _} = obj) do

    # obj = Bonfire.Repo.maybe_preload(obj, [:icon, :image])

    # icon = Bonfire.Files.IconUploader.remote_url(obj.icon)
    # image = Bonfire.Files.ImageUploader.remote_url(obj.image)

    %{
      "index_type" => Bonfire.Data.Social.PostContent,
      "name" => obj.name,
      "summary" => obj.summary,
      "html_body" => obj.html_body,
      # "icon" => %{"url"=> icon},
      # "image" => %{"url"=> image},
   }
  end

  def indexing_object_format(_), do: nil

  def changeset(%PostContent{} = cs \\ %PostContent{} , attrs) do
    PostContent.changeset(cs, attrs)
  end

end
