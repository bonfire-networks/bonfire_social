defmodule Bonfire.Social.PostContents do


  def prepare_content(attrs, text \\ nil)
  def prepare_content(%{post_content: %{} = attrs}, text), do: prepare_content(attrs, text)
  def prepare_content(attrs, text) when is_binary(text) and bit_size(text) > 0 do
    # use text overide if provided
    Map.merge(attrs, %{html_body: text})
  end
  def prepare_content(%{name: name, html_body: body} = attrs, _) when is_nil(body) or body=="" do
    # use title as body if no body entered
    Map.merge(attrs, %{html_body: name, name: ""})
  end
  def prepare_content(attrs, _), do: attrs


end
