defmodule Bonfire.Social.Test.FakeHelpers do

  def post_attrs(n), do: %{post_content: %{summary: "summary", name: "post ##{n}", html_body: "<p>epic html message</p>"}}

  def post_attrs(n, attrs), do: Map.merge(attrs, %{post_content: %{name: "post ##{n}", html_body: "<p>epic html message</p>"}})

end
