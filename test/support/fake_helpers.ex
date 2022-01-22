defmodule Bonfire.Social.Test.FakeHelpers do

  alias Bonfire.Data.Identity.Account
  alias Bonfire.Me.Fake
  alias Bonfire.Me.{Accounts, Users}
  import ExUnit.Assertions

  import Bonfire.Social.Integration
  import Bonfire.Me.Fake

  def post_attrs(n, attrs \\ %{}), do: Map.merge(%{post_content: %{summary: "summary", name: "#{n}", html_body: "<p>epic html message</p>"}}, attrs)

end
