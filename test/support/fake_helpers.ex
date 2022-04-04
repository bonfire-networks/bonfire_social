defmodule Bonfire.Social.Test.FakeHelpers do

  def post_attrs(n, attrs \\ %{}), do: Map.merge(%{post_content: %{summary: "summary", name: "#{n}", html_body: "<p>epic html message</p>"}}, attrs)

end
